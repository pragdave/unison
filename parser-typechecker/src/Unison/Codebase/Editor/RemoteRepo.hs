{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Unison.Codebase.Editor.RemoteRepo where

import qualified Data.Text as Text
import qualified Servant.Client as Servant
import qualified U.Util.Monoid as Monoid
import Unison.Codebase.Path (Path)
import qualified Unison.Codebase.Path as Path
import Unison.Codebase.ShortBranchHash (ShortBranchHash)
import qualified Unison.Codebase.ShortBranchHash as SBH
import Unison.Prelude

data ReadRepo
  = ReadRepoGit ReadGitRepo
  | ReadRepoShare ShareRepo
  deriving (Eq, Show)

data ReadGitRepo = ReadGitRepo {url :: Text, ref :: Maybe Text}
  deriving (Eq, Show)

-- FIXME rename to ShareServer
data ShareRepo = ShareRepo
  deriving (Eq, Show)

shareRepoToBaseUrl :: ShareRepo -> Servant.BaseUrl
shareRepoToBaseUrl ShareRepo = Servant.BaseUrl Servant.Https "share.unison.cloud" 443 ""

data WriteRepo
  = WriteRepoGit WriteGitRepo
  | WriteRepoShare ShareRepo
  deriving (Eq, Show)

data WriteGitRepo = WriteGitRepo {url :: Text, branch :: Maybe Text}
  deriving (Eq, Show)

writeToRead :: WriteRepo -> ReadRepo
writeToRead = \case
  WriteRepoGit repo -> ReadRepoGit (writeToReadGit repo)
  WriteRepoShare repo -> ReadRepoShare repo

writeToReadGit :: WriteGitRepo -> ReadGitRepo
writeToReadGit = \case
  WriteGitRepo {url, branch} -> ReadGitRepo {url = url, ref = branch}

writePathToRead :: WriteRemotePath -> ReadRemoteNamespace
writePathToRead = \case
  WriteRemotePathGit WriteGitRemotePath {repo, path} ->
    ReadRemoteNamespaceGit ReadGitRemoteNamespace {repo = writeToReadGit repo, sbh = Nothing, path}
  WriteRemotePathShare WriteShareRemotePath {server, repo, path} ->
    ReadRemoteNamespaceShare ReadShareRemoteNamespace {server, repo, path}

printReadRepo :: ReadRepo -> Text
printReadRepo = \case
  ReadRepoGit ReadGitRepo {url, ref} -> url <> Monoid.fromMaybe (Text.cons ':' <$> ref)
  ReadRepoShare s -> printShareRepo s

printShareRepo :: ShareRepo -> Text
printShareRepo = const "PLACEHOLDER"

printWriteRepo :: WriteRepo -> Text
printWriteRepo = \case
  WriteRepoGit WriteGitRepo {url, branch} -> url <> Monoid.fromMaybe (Text.cons ':' <$> branch)
  WriteRepoShare s -> printShareRepo s

-- | print remote namespace
printNamespace :: ReadRemoteNamespace -> Text
printNamespace = \case
  ReadRemoteNamespaceGit ReadGitRemoteNamespace {repo, sbh, path} ->
    printReadRepo (ReadRepoGit repo) <> case sbh of
      Nothing ->
        if path == Path.empty
          then mempty
          else ":." <> Path.toText path
      Just sbh ->
        ":#" <> SBH.toText sbh
          <> if path == Path.empty
            then mempty
            else "." <> Path.toText path

-- | Render a 'WriteRemotePath' as text.
printWriteRemotePath :: WriteRemotePath -> Text
printWriteRemotePath = \case
  WriteRemotePathGit WriteGitRemotePath {repo, path} -> wundefined
  WriteRemotePathShare WriteShareRemotePath {server, repo, path} -> wundefined

-- | print remote path
printHead :: WriteRepo -> Path -> Text
printHead repo path =
  printWriteRepo repo
    <> if path == Path.empty then mempty else ":." <> Path.toText path

data ReadRemoteNamespace
  = ReadRemoteNamespaceGit ReadGitRemoteNamespace
  | ReadRemoteNamespaceShare ReadShareRemoteNamespace
  deriving stock (Eq, Show)

data ReadGitRemoteNamespace = ReadGitRemoteNamespace
  { repo :: ReadGitRepo,
    sbh :: Maybe ShortBranchHash,
    path :: Path
  }
  deriving stock (Eq, Show)

data ReadShareRemoteNamespace = ReadShareRemoteNamespace
  { server :: ShareRepo,
    repo :: Text,
    -- sbh :: Maybe ShortBranchHash, -- maybe later
    path :: Path
  }
  deriving stock (Eq, Show)

data WriteRemotePath
  = WriteRemotePathGit WriteGitRemotePath
  | WriteRemotePathShare WriteShareRemotePath
  deriving stock (Eq, Show)

data WriteGitRemotePath = WriteGitRemotePath
  { repo :: WriteGitRepo,
    path :: Path
  }
  deriving stock (Eq, Show)

data WriteShareRemotePath = WriteShareRemotePath
  { server :: ShareRepo,
    repo :: Text,
    path :: Path
  }
  deriving stock (Eq, Show)
