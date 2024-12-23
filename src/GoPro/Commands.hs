{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE DataKinds            #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE UndecidableInstances #-}

module GoPro.Commands where

import           Amazonka.S3         (BucketName (..))
import           Cleff
import           Cleff.Fail
import           Cleff.Reader
import           Data.List.NonEmpty  (NonEmpty (..))
import qualified Data.Map.Strict     as Map
import qualified Data.Text           as T

import           GoPro.AuthCache
import           GoPro.Config.Effect
import           GoPro.DB
import           GoPro.Logging
import           GoPro.Notification
import           GoPro.Plus.Media    (FileInfo, MediumID, MediumType)
import           GoPro.RunDB
import           GoPro.S3

-- Extractor function for deciding which files to download for backing up.
-- (medium id, head url, url)
type Extractor = MediumID -> FileInfo -> [(T.Text, String, String)]

data Command = AuthCmd
             | ReauthCmd
             | SyncCmd
             | RefreshCmd (NonEmpty MediumID)
             | CreateUploadCmd (NonEmpty FilePath)
             | UploadCmd [FilePath]
             | CreateMultiCmd MediumType (NonEmpty FilePath)
             | FetchAllCmd
             | RemoveDeleted
             | CleanupCmd
             | FixupCmd T.Text
             | ServeCmd
             | WaitCmd
             | ReprocessCmd (NonEmpty MediumID)
             | BackupCmd Extractor
             | ProcessSQSCmd
             | BackupLocalCmd Extractor (NonEmpty FilePath)
             | DownloadCmd Extractor FilePath (NonEmpty MediumID)
             | ConfigListCmd
             | ConfigGetCmd ConfigOption
             | ConfigSetCmd ConfigOption T.Text
             | ClearMetaCmd

instance Show Command where show = const "[command]"

data Options = Options
    { optDBPath              :: String
    , optStaticPath          :: FilePath
    , optVerbose             :: Bool
    , optUploadConcurrency   :: Int
    , optDownloadConcurrency :: Int
    , optChunkSize           :: Integer
    , optReferenceDir        :: Maybe FilePath
    , optCommand             :: Command
    } deriving Show

defaultOptions :: Options
defaultOptions = Options
    { optDBPath = "gopro.db"
    , optStaticPath = "static"
    , optVerbose = False
    , optUploadConcurrency = 3
    , optDownloadConcurrency = 11
    , optChunkSize = 6*1024*1024
    , optReferenceDir = Nothing
    , optCommand  = AuthCmd -- this should not be used
    }

asksOpt :: Reader Options :> es => (Options -> b) -> Eff es b
asksOpt = asks

tshow :: Show a => a -> T.Text
tshow = T.pack . show

runWithOptions :: Options -> (forall es. [IOE, AuthCache, ConfigFX, NotifyFX, DB, S3, LogFX, Fail, Reader Options] :>> es => Eff es a) -> IO a
runWithOptions o@Options{..} a = runIOE . runFailIO $ withDB optDBPath $ do
  initTables
  cfg <- loadConfig
  cacheData <- newAuthCacheData
  tc <- liftIO mkLogChannel
  s3runner <- case Map.findWithDefault "" CfgBucket cfg of
    "" -> pure unconfiguredS3
    bn -> pure $ runS3 (BucketName bn)
  runReader o . runLogFX tc optVerbose . runNotify tc . runConfig cfg . runAuthCache cacheData . s3runner $ a

