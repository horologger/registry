{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Handler.Admin where

import Conduit (
    runConduit,
    sinkFile,
    (.|),
 )
import Control.Exception (ErrorCall (ErrorCall))
import Control.Monad.Reader.Has (ask)
import Control.Monad.Trans.Maybe (MaybeT (..))
import Data.Aeson (
    FromJSON (parseJSON),
    ToJSON,
    decodeFileStrict,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
 )
import Data.HashMap.Internal.Strict (
    HashMap,
    differenceWith,
    filter,
    fromListWith,
 )
import Data.List (
    null,
    (\\),
 )
import Data.String.Interpolate.IsString (
    i,
 )
import Database.Persist (
    Entity (entityKey),
    PersistStoreRead (get),
    PersistUniqueRead (getBy),
    PersistUniqueWrite (deleteBy, insertUnique, upsert),
    entityVal,
    insert_,
    selectList,
 )
import Database.Persist.Postgresql (runSqlPoolNoTransaction)
import Database.Queries (upsertPackageVersion)
import Foundation (
    Handler,
    RegistryCtx (..),
 )
import Handler.Util (
    orThrow,
    sendResponseText,
 )
import Lib.PkgRepository (
    PkgRepo (PkgRepo, pkgRepoFileRoot),
    extractPkg,
    getManifestLocation,
    getPackages,
    getVersionsFor,
 )
import Lib.Types.AppIndex (
    PackageManifest (..),
    PkgId (unPkgId),
 )
import Lib.Types.Emver (Version (..))
import Model (
    Category (..),
    Key (AdminKey, PkgRecordKey, VersionRecordKey),
    PkgCategory (PkgCategory),
    Unique (UniqueName, UniquePkgCategory),
    Upload (..),
    VersionRecord (versionRecordNumber, versionRecordPkgId),
    unPkgRecordKey,
 )
import Network.HTTP.Types (
    status403,
    status404,
    status500,
 )
import Settings
import Startlude (
    Applicative (pure),
    Bool (..),
    Eq,
    Int,
    Maybe (..),
    Monad ((>>=)),
    Show,
    SomeException (..),
    Text,
    asum,
    fmap,
    fromMaybe,
    getCurrentTime,
    guarded,
    hush,
    isNothing,
    liftIO,
    not,
    replicate,
    show,
    throwIO,
    toS,
    traverse,
    void,
    when,
    zip,
    ($),
    (&&&),
    (.),
    (.*),
    (<$>),
    (<<$>>),
    (<>),
 )
import System.FilePath (
    (<.>),
    (</>),
 )
import UnliftIO (
    try,
    withTempDirectory,
 )
import UnliftIO.Directory (
    createDirectoryIfMissing,
    removePathForcibly,
    renameDirectory,
    renameFile,
 )
import Yesod (
    ToJSON (..),
    delete,
    getsYesod,
    logError,
    rawRequestBody,
    requireCheckJsonBody,
    runDB,
 )
import Yesod.Auth (YesodAuth (maybeAuthId))
import Yesod.Core.Types (JSONResponse (JSONResponse))


postPkgUploadR :: Handler ()
postPkgUploadR = do
    resourcesTemp <- getsYesod $ (</> "temp") . resourcesDir . appSettings
    createDirectoryIfMissing True resourcesTemp
    withTempDirectory resourcesTemp "newpkg" $ \dir -> do
        let path = dir </> "temp" <.> "s9pk"
        runConduit $ rawRequestBody .| sinkFile path
        pool <- getsYesod appConnPool
        PkgRepo{..} <- ask
        res <- retry $ extractPkg pool path
        when (isNothing res) $ do
            $logError "Failed to extract package"
            sendResponseText status500 "Failed to extract package"
        PackageManifest{..} <-
            liftIO (decodeFileStrict (dir </> "manifest.json"))
                `orThrow` sendResponseText status500 "Failed to parse manifest.json"
        renameFile path (dir </> (toS . unPkgId) packageManifestId <.> "s9pk")
        let targetPath = pkgRepoFileRoot </> show packageManifestId </> show packageManifestVersion
        removePathForcibly targetPath
        createDirectoryIfMissing True targetPath
        renameDirectory dir targetPath
        maybeAuthId >>= \case
            Nothing -> do
                -- TODO: Send this to Matrix
                $logError
                    "The Impossible has happened, an unauthenticated user has managed to upload a pacakge to this registry"
                throwIO $ ErrorCall "Unauthenticated user has uploaded package to registry!!!"
            Just name -> do
                now <- liftIO getCurrentTime
                runDB $ insert_ (Upload (AdminKey name) (PkgRecordKey packageManifestId) packageManifestVersion now)
    where
        retry m = runMaybeT . asum $ replicate 3 (MaybeT $ hush <$> try @_ @SomeException m)


data IndexPkgReq = IndexPkgReq
    { indexPkgReqId :: !PkgId
    , indexPkgReqVersion :: !Version
    }
    deriving (Eq, Show)
instance FromJSON IndexPkgReq where
    parseJSON = withObject "Index Package Request" $ \o -> do
        indexPkgReqId <- o .: "id"
        indexPkgReqVersion <- o .: "version"
        pure IndexPkgReq{..}
instance ToJSON IndexPkgReq where
    toJSON IndexPkgReq{..} = object ["id" .= indexPkgReqId, "version" .= indexPkgReqVersion]


postPkgIndexR :: Handler ()
postPkgIndexR = do
    IndexPkgReq{..} <- requireCheckJsonBody
    manifest <- getManifestLocation indexPkgReqId indexPkgReqVersion
    man <-
        liftIO (decodeFileStrict manifest)
            `orThrow` sendResponseText
                status404
                [i|Could not locate manifest for #{indexPkgReqId}@#{indexPkgReqVersion}|]
    pool <- getsYesod appConnPool
    runSqlPoolNoTransaction (upsertPackageVersion man) pool Nothing


postPkgDeindexR :: Handler ()
postPkgDeindexR = do
    IndexPkgReq{..} <- requireCheckJsonBody
    runDB $ delete (VersionRecordKey (PkgRecordKey indexPkgReqId) indexPkgReqVersion)


newtype PackageList = PackageList {unPackageList :: HashMap PkgId [Version]}
instance FromJSON PackageList where
    parseJSON = fmap PackageList . parseJSON
instance ToJSON PackageList where
    toJSON = toJSON . unPackageList


getPkgDeindexR :: Handler (JSONResponse PackageList)
getPkgDeindexR = do
    dbList <-
        runDB $
            (unPkgRecordKey . versionRecordPkgId &&& (: []) . versionRecordNumber)
                . entityVal
                <<$>> selectList [] []
    let inDb = fromListWith (<>) dbList
    pkgsOnDisk <- getPackages
    onDisk <- fromListWith (<>) . zip pkgsOnDisk <$> traverse getVersionsFor pkgsOnDisk
    pure . JSONResponse . PackageList $ filter (not . null) $ differenceWith (guarded null .* (\\)) onDisk inDb


data AddCategoryReq = AddCategoryReq
    { addCategoryDescription :: !(Maybe Text)
    , addCategoryPriority :: !(Maybe Int)
    }
instance FromJSON AddCategoryReq where
    parseJSON = withObject "AddCategoryReq" $ \o -> do
        addCategoryDescription <- o .:? "description"
        addCategoryPriority <- o .:? "priority"
        pure AddCategoryReq{..}
instance ToJSON AddCategoryReq where
    toJSON AddCategoryReq{..} = object ["description" .= addCategoryDescription, "priority" .= addCategoryPriority]


postCategoryR :: Text -> Handler ()
postCategoryR cat = do
    AddCategoryReq{..} <- requireCheckJsonBody
    now <- liftIO getCurrentTime
    void . runDB $ upsert (Category now cat (fromMaybe "" addCategoryDescription) (fromMaybe 0 addCategoryPriority)) []


deleteCategoryR :: Text -> Handler ()
deleteCategoryR cat = runDB $ deleteBy (UniqueName cat)


postPkgCategorizeR :: Text -> PkgId -> Handler ()
postPkgCategorizeR cat pkg = runDB $ do
    catEnt <- getBy (UniqueName cat) `orThrow` sendResponseText status404 [i|Category "#{cat}" does not exist|]
    _pkgEnt <- get (PkgRecordKey pkg) `orThrow` sendResponseText status404 [i|Package "#{pkg}" does not exist|]
    now <- liftIO getCurrentTime
    void $
        insertUnique (PkgCategory now (PkgRecordKey pkg) (entityKey catEnt))
            `orThrow` sendResponseText
                status403
                [i|Package "#{pkg}" is already assigned to category "#{cat}"|]


deletePkgCategorizeR :: Text -> PkgId -> Handler ()
deletePkgCategorizeR cat pkg = runDB $ do
    catEnt <- getBy (UniqueName cat) `orThrow` sendResponseText status404 [i|Category "#{cat}" does not exist|]
    deleteBy (UniquePkgCategory (PkgRecordKey pkg) (entityKey catEnt))
