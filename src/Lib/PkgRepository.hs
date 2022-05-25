{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-name-shadowing #-}
{-# LANGUAGE GADTs #-}

module Lib.PkgRepository where

import           Conduit                        ( (.|)
                                                , ConduitT
                                                , MonadResource
                                                , runConduit
                                                , runResourceT
                                                , sinkFileCautious
                                                , sourceFile
                                                )
import           Control.Monad.Logger           ( MonadLogger
                                                , MonadLoggerIO
                                                , logError
                                                , logInfo
                                                , logWarn
                                                )
import           Control.Monad.Reader.Has       ( Has
                                                , ask
                                                , asks
                                                )
import           Crypto.Hash                    ( SHA256 )
import           Crypto.Hash.Conduit            ( hashFile )
import           Data.Aeson                     ( eitherDecodeFileStrict' )
import qualified Data.Attoparsec.Text          as Atto
import           Data.Attoparsec.Text           ( parseOnly )
import           Data.ByteArray.Encoding        ( Base(Base16)
                                                , convertToBase
                                                )
import           Data.ByteString                ( readFile
                                                , writeFile
                                                )
import qualified Data.HashMap.Strict           as HM
import           Data.String.Interpolate.IsString
                                                ( i )
import qualified Data.Text                     as T
import           Data.Time                      ( getCurrentTime )
import           Database.Esqueleto.Experimental
                                                ( ConnectionPool
                                                , insertUnique
                                                , runSqlPool
                                                )
import           Database.Persist               ( (=.)
                                                , insertKey
                                                , update
                                                , upsert
                                                )
import           Database.Persist.Sql           ( SqlPersistT
                                                , runSqlPoolNoTransaction
                                                )
import           Database.PostgreSQL.Simple     ( SqlError(sqlState) )
import           Lib.Error                      ( S9Error(NotFoundE) )
import qualified Lib.External.AppMgr           as AppMgr
import           Lib.Types.AppIndex             ( PackageManifest(..)
                                                , PkgId(..)
                                                , packageDependencyVersion
                                                , packageManifestDependencies
                                                )
import           Lib.Types.Emver                ( Version
                                                , VersionRange
                                                , parseVersion
                                                , satisfies
                                                )
import           Model
import           Startlude                      ( ($)
                                                , (&&)
                                                , (.)
                                                , (/=)
                                                , (<$>)
                                                , Bool(..)
                                                , ByteString
                                                , Down(..)
                                                , Either(..)
                                                , Eq((==))
                                                , Exception
                                                , FilePath
                                                , IO
                                                , Integer
                                                , Maybe(..)
                                                , MonadIO(liftIO)
                                                , MonadReader
                                                , Ord(compare)
                                                , Show
                                                , SomeException(..)
                                                , decodeUtf8
                                                , filter
                                                , find
                                                , first
                                                , flip
                                                , for_
                                                , fst
                                                , headMay
                                                , not
                                                , on
                                                , partitionEithers
                                                , pure
                                                , show
                                                , snd
                                                , sortBy
                                                , throwIO
                                                , void
                                                )
import           System.FSNotify                ( ActionPredicate
                                                , Event(..)
                                                , eventPath
                                                , watchTree
                                                , withManager
                                                )
import           System.FilePath                ( (<.>)
                                                , (</>)
                                                , takeBaseName
                                                , takeDirectory
                                                , takeExtension
                                                , takeFileName
                                                )
import           UnliftIO                       ( MonadUnliftIO
                                                , askRunInIO
                                                , async
                                                , catch
                                                , mapConcurrently_
                                                , newEmptyMVar
                                                , takeMVar
                                                , tryPutMVar
                                                , wait
                                                )
import           UnliftIO.Concurrent            ( forkIO )
import           UnliftIO.Directory             ( doesDirectoryExist
                                                , doesPathExist
                                                , getFileSize
                                                , listDirectory
                                                , removeFile
                                                , renameFile
                                                )
import           UnliftIO.Exception             ( handle )
import           Yesod.Core.Content             ( typeGif
                                                , typeJpeg
                                                , typePlain
                                                , typePng
                                                , typeSvg
                                                )
import           Yesod.Core.Types               ( ContentType )

newtype ManifestParseException = ManifestParseException FilePath
    deriving Show
instance Exception ManifestParseException

data PkgRepo = PkgRepo
    { pkgRepoFileRoot  :: FilePath
    , pkgRepoAppMgrBin :: FilePath
    }

newtype EosRepo = EosRepo
    { eosRepoFileRoot :: FilePath
    }

getVersionsFor :: (MonadIO m, MonadReader r m, Has PkgRepo r, MonadLogger m) => PkgId -> m [Version]
getVersionsFor pkg = do
    root <- asks pkgRepoFileRoot
    let pkgDir = root </> show pkg
    exists <- doesDirectoryExist pkgDir
    if exists
        then do
            subdirs <- listDirectory pkgDir
            let (failures, successes) = partitionEithers $ Atto.parseOnly parseVersion . T.pack <$> subdirs
            for_ failures $ \f -> $logWarn [i|Emver Parse Failure for #{pkg}: #{f}|]
            pure successes
        else pure []

getViableVersions :: (MonadIO m, MonadReader r m, Has PkgRepo r, MonadLogger m) => PkgId -> VersionRange -> m [Version]
getViableVersions pkg spec = filter (`satisfies` spec) <$> getVersionsFor pkg

getBestVersion :: (MonadIO m, MonadReader r m, Has PkgRepo r, MonadLogger m)
               => PkgId
               -> VersionRange
               -> Bool
               -> m (Maybe Version)
getBestVersion pkg spec preferMin = headMay . sortBy comparator <$> getViableVersions pkg spec
    where comparator = if preferMin then compare else compare `on` Down

loadPkgDependencies :: MonadUnliftIO m => ConnectionPool -> PackageManifest -> m ()
loadPkgDependencies appConnPool manifest = do
    let pkgId      = packageManifestId manifest
    let pkgVersion = packageManifestVersion manifest
    let deps       = packageManifestDependencies manifest
    time <- liftIO getCurrentTime
    _    <- runWith appConnPool $ insertKey (PkgRecordKey pkgId) (PkgRecord time Nothing) `catch` \(e :: SqlError) ->
        if sqlState e == "23505" then update (PkgRecordKey pkgId) [PkgRecordUpdatedAt =. Just time] else throwIO e
    let deps' = first PkgRecordKey <$> HM.toList deps
    for_
        deps'
        (\d -> flip runSqlPool appConnPool $ do
            insertUnique
                $ PkgDependency time (PkgRecordKey pkgId) pkgVersion (fst d) (packageDependencyVersion . snd $ d)
        )
    where
        runWith :: MonadUnliftIO m => ConnectionPool -> SqlPersistT m a -> m a
        runWith pool action = runSqlPoolNoTransaction action pool Nothing

-- extract all package assets into their own respective files
extractPkg :: (MonadUnliftIO m, MonadReader r m, Has PkgRepo r, MonadLoggerIO m) => ConnectionPool -> FilePath -> m ()
extractPkg pool fp = handle @_ @SomeException cleanup $ do
    $logInfo [i|Extracting package: #{fp}|]
    PkgRepo { pkgRepoAppMgrBin = appmgr } <- ask
    let pkgRoot = takeDirectory fp
    manifestTask     <- async $ runResourceT $ AppMgr.sourceManifest appmgr fp $ sinkIt (pkgRoot </> "manifest.json")
    pkgHashTask      <- async $ AppMgr.getPackageHash appmgr fp
    instructionsTask <- async $ runResourceT $ AppMgr.sourceInstructions appmgr fp $ sinkIt
        (pkgRoot </> "instructions.md")
    licenseTask <- async $ runResourceT $ AppMgr.sourceLicense appmgr fp $ sinkIt (pkgRoot </> "license.md")
    iconTask    <- async $ runResourceT $ AppMgr.sourceIcon appmgr fp $ sinkIt (pkgRoot </> "icon.tmp")
    wait manifestTask
    eManifest <- liftIO (eitherDecodeFileStrict' (pkgRoot </> "manifest.json"))
    case eManifest of
        Left _ -> do
            $logError [i|Invalid Package Manifest: #{fp}|]
            liftIO . throwIO $ ManifestParseException (pkgRoot </> "manifest.json")
        Right manifest -> do
            wait iconTask
            let iconDest = "icon" <.> case packageManifestIcon manifest of
                    Nothing -> "png"
                    Just x  -> case takeExtension (T.unpack x) of
                        ""    -> "png"
                        other -> other
            loadPkgDependencies pool manifest
            liftIO $ renameFile (pkgRoot </> "icon.tmp") (pkgRoot </> iconDest)
    hash <- wait pkgHashTask
    liftIO $ writeFile (pkgRoot </> "hash.bin") hash
    wait instructionsTask
    wait licenseTask
    where
        sinkIt fp source = runConduit $ source .| sinkFileCautious fp
        cleanup e = do
            $logError $ show e
            let pkgRoot = takeDirectory fp
            fs <- listDirectory pkgRoot
            let toRemove = filter ((/=) ".s9pk" . takeExtension) fs
            mapConcurrently_ (removeFile . (pkgRoot </>)) toRemove
            throwIO e

watchEosRepoRoot :: (MonadUnliftIO m, MonadReader r m, Has EosRepo r, MonadLoggerIO m) => ConnectionPool -> m (IO Bool)
watchEosRepoRoot pool = do
    $logInfo "Starting FSNotify Watch Manager: EOS"
    root    <- asks eosRepoFileRoot
    runInIO <- askRunInIO
    box     <- newEmptyMVar @_ @()
    _       <- forkIO $ liftIO $ withManager $ \watchManager -> do
        stop <- watchTree watchManager root shouldIndex $ \evt -> do
            let os = eventPath evt
            void . forkIO $ runInIO $ do
                indexOs pool os
        takeMVar box
        stop
    pure $ tryPutMVar box ()
    where
        shouldIndex :: ActionPredicate
        shouldIndex (Added    path _ isDir) = not isDir && takeExtension path == ".img"
        shouldIndex (Modified path _ isDir) = not isDir && takeExtension path == ".img"
        shouldIndex _                       = False
        indexOs :: (MonadUnliftIO m, MonadLoggerIO m) => ConnectionPool -> FilePath -> m ()
        indexOs pool path = do
            hash <- hashFile @_ @SHA256 path
            let hashText = decodeUtf8 $ convertToBase Base16 hash
            let vText    = takeFileName (takeDirectory path)
            let eVersion = parseOnly parseVersion . T.pack $ vText
            case eVersion of
                Left e -> $logError [i|Invalid Version Number (#{vText}): #{e}|]
                Right version ->
                    void $ flip runSqlPool pool $ upsert (EosHash version hashText) [EosHashHash =. hashText]

getManifestLocation :: (MonadReader r m, Has PkgRepo r) => PkgId -> Version -> m FilePath
getManifestLocation pkg version = do
    root <- asks pkgRepoFileRoot
    pure $ root </> show pkg </> show version </> "manifest.json"

getManifest :: (MonadResource m, MonadReader r m, Has PkgRepo r)
            => PkgId
            -> Version
            -> m (Integer, ConduitT () ByteString m ())
getManifest pkg version = do
    manifestPath <- getManifestLocation pkg version
    n            <- getFileSize manifestPath
    pure (n, sourceFile manifestPath)

getInstructions :: (MonadResource m, MonadReader r m, Has PkgRepo r)
                => PkgId
                -> Version
                -> m (Integer, ConduitT () ByteString m ())
getInstructions pkg version = do
    root <- asks pkgRepoFileRoot
    let instructionsPath = root </> show pkg </> show version </> "instructions.md"
    n <- getFileSize instructionsPath
    pure (n, sourceFile instructionsPath)

getLicense :: (MonadResource m, MonadReader r m, Has PkgRepo r)
           => PkgId
           -> Version
           -> m (Integer, ConduitT () ByteString m ())
getLicense pkg version = do
    root <- asks pkgRepoFileRoot
    let licensePath = root </> show pkg </> show version </> "license.md"
    n <- getFileSize licensePath
    pure (n, sourceFile licensePath)

getIcon :: (MonadResource m, MonadReader r m, Has PkgRepo r)
        => PkgId
        -> Version
        -> m (ContentType, Integer, ConduitT () ByteString m ())
getIcon pkg version = do
    root <- asks pkgRepoFileRoot
    let pkgRoot = root </> show pkg </> show version
    mIconFile <- find ((== "icon") . takeBaseName) <$> listDirectory pkgRoot
    case mIconFile of
        Nothing -> throwIO $ NotFoundE [i|#{pkg}: Icon|]
        Just x  -> do
            let ct = case takeExtension x of
                    ".png"  -> typePng
                    ".jpg"  -> typeJpeg
                    ".jpeg" -> typeJpeg
                    ".svg"  -> typeSvg
                    ".gif"  -> typeGif
                    _       -> typePlain
            n <- getFileSize (pkgRoot </> x)
            pure (ct, n, sourceFile (pkgRoot </> x))

getHash :: (MonadIO m, MonadReader r m, Has PkgRepo r) => PkgId -> Version -> m ByteString
getHash pkg version = do
    root <- asks pkgRepoFileRoot
    let hashPath = root </> show pkg </> show version </> "hash.bin"
    liftIO $ readFile hashPath

getPackage :: (MonadResource m, MonadReader r m, Has PkgRepo r) => PkgId -> Version -> m (Maybe FilePath)
getPackage pkg version = do
    root <- asks pkgRepoFileRoot
    let pkgPath = root </> show pkg </> show version </> show pkg <.> "s9pk"
    found <- doesPathExist pkgPath
    pure $ if found then Just pkgPath else Nothing
