{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE QuasiQuotes      #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies     #-}

module Lib.External.AppMgr where

import           Startlude

import qualified Data.ByteString.Lazy          as LBS
import           Data.String.Interpolate.IsString
import           System.Process.Typed    hiding ( createPipe )

import           Lib.Error
import           Lib.Registry

readProcessWithExitCode' :: MonadIO m => String -> [String] -> ByteString -> m (ExitCode, ByteString, ByteString)
readProcessWithExitCode' a b c = liftIO $ do
    let pc =
            setStdin (byteStringInput $ LBS.fromStrict c)
                $ setStderr byteStringOutput
                $ setEnvInherit
                $ setStdout byteStringOutput
                $ (System.Process.Typed.proc a b)
    withProcessWait pc $ \process -> atomically $ liftA3 (,,)
                                                         (waitExitCodeSTM process)
                                                         (fmap LBS.toStrict $ getStdout process)
                                                         (fmap LBS.toStrict $ getStderr process)

readProcessInheritStderr :: MonadIO m => String -> [String] -> ByteString -> m (ExitCode, ByteString)
readProcessInheritStderr a b c = liftIO $ do
    let pc =
            setStdin (byteStringInput $ LBS.fromStrict c)
                $ setStderr inherit
                $ setEnvInherit
                $ setStdout byteStringOutput
                $ (System.Process.Typed.proc a b)
    withProcessWait pc
        $ \process -> atomically $ liftA2 (,) (waitExitCodeSTM process) (fmap LBS.toStrict $ getStdout process)

getConfig :: (MonadIO m, KnownSymbol a) => FilePath -> FilePath -> Extension a -> S9ErrT m Text
getConfig appmgrPath appPath e@(Extension appId) = fmap decodeUtf8 $ do
    (ec, out) <- readProcessInheritStderr (appmgrPath <> "appmgr") ["inspect", "info", appPath <> (show e), "-C", "--json"] ""
    case ec of
        ExitSuccess   -> pure out
        ExitFailure n -> throwE $ AppMgrE [i|info #{appId} -C \--json|] n

getManifest ::  (MonadIO m, KnownSymbol a)  => FilePath -> FilePath ->  Extension a -> S9ErrT m ByteString
getManifest appmgrPath appPath e@(Extension appId) = do
    (ec, bs) <- readProcessInheritStderr (appmgrPath <> "appmgr") ["inspect", "info", appPath <> (show e), "-M", "--json"] ""
    case ec of
        ExitSuccess -> pure bs
        ExitFailure n -> throwE $ AppMgrE [i|info -M #{appId} \--json|] n