module Unison.Codebase.Editor.HandleInput.AuthLogin
  ( authLogin,
    ensureAuthenticatedWithCodeserver,
  )
where

import Control.Concurrent.MVar
import Control.Monad.Reader
import qualified Crypto.Hash as Crypto
import Crypto.Random (getRandomBytes)
import qualified Data.Aeson as Aeson
import qualified Data.ByteArray.Encoding as BE
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import Network.HTTP.Client (urlEncodedBody)
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Client.TLS as HTTP
import Network.HTTP.Types
import Network.URI (URI (..), parseURI)
import Network.Wai
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import Unison.Auth.CredentialManager (getCredentials, saveCredentials)
import Unison.Auth.Discovery (discoveryURIForCodeserver, fetchDiscoveryDoc)
import Unison.Auth.Types
  ( Code,
    CredentialFailure (..),
    DiscoveryDoc (..),
    OAuthState,
    PKCEChallenge,
    PKCEVerifier,
    Tokens,
    codeserverCredentials,
  )
import Unison.Cli.Monad (Cli)
import qualified Unison.Cli.Monad as Cli
import qualified Unison.Codebase.Editor.Output as Output
import qualified Unison.Debug as Debug
import Unison.Prelude
import Unison.Share.Types
import qualified Web.Browser as Web

ucmOAuthClientID :: ByteString
ucmOAuthClientID = "ucm"

-- | Checks if the user has valid auth for the given codeserver,
-- and runs through an authentication flow if not.
ensureAuthenticatedWithCodeserver :: CodeserverURI -> Cli ()
ensureAuthenticatedWithCodeserver codeserverURI = do
  Cli.Env {credentialManager} <- ask
  getCredentials credentialManager (codeserverIdFromCodeserverURI codeserverURI) >>= \case
    Right _ -> pure ()
    Left _ -> authLogin codeserverURI

-- | Direct the user through an authentication flow with the given server and store the credentials in the provided
-- credential manager.
authLogin :: CodeserverURI -> Cli ()
authLogin host = do
  Cli.Env {credentialManager} <- ask
  httpClient <- liftIO HTTP.getGlobalManager
  let discoveryURI = discoveryURIForCodeserver host
  doc@(DiscoveryDoc {authorizationEndpoint, tokenEndpoint}) <-
    Cli.ioE (fetchDiscoveryDoc discoveryURI) \err -> do
      Cli.returnEarly (Output.CredentialFailureMsg err)
  Debug.debugM Debug.Auth "Discovery Doc" doc
  authResultVar <- liftIO (newEmptyMVar @(Either CredentialFailure Tokens))
  -- The redirect_uri depends on the port, so we need to spin up the server first, but
  -- we can't spin up the server without the code-handler which depends on the redirect_uri.
  -- So, annoyingly we just embed an MVar which will be filled as soon as the server boots up,
  -- and it all works out fine.
  redirectURIVar <- liftIO newEmptyMVar
  (verifier, challenge, state) <- generateParams
  let codeHandler :: (Code -> Maybe URI -> (Response -> IO ResponseReceived) -> IO ResponseReceived)
      codeHandler code mayNextURI respond = do
        redirectURI <- readMVar redirectURIVar
        result <- exchangeCode httpClient tokenEndpoint code verifier redirectURI
        respReceived <- case result of
          Left err -> do
            Debug.debugM Debug.Auth "Auth Error" err
            respond $ Wai.responseLBS internalServerError500 [] "Something went wrong, please try again."
          Right _ ->
            case mayNextURI of
              Nothing -> respond $ Wai.responseLBS found302 [] "Authorization successful. You may close this page and return to UCM."
              Just nextURI ->
                respond $
                  Wai.responseLBS
                    found302
                    [("LOCATION", BSC.pack $ show @URI nextURI)]
                    "Authorization successful. You may close this page and return to UCM."
        -- Wait until we've responded to the browser before putting the result,
        -- otherwise the server will shut down prematurely.
        putMVar authResultVar result
        pure respReceived
  tokens <-
    Cli.with (Warp.withApplication (pure $ authTransferServer codeHandler)) \port -> do
      let redirectURI = "http://localhost:" <> show port <> "/redirect"
      liftIO (putMVar redirectURIVar redirectURI)
      let authorizationKickoff = authURI authorizationEndpoint redirectURI state challenge
      void . liftIO $ Web.openBrowser (show authorizationKickoff)
      Cli.respond . Output.InitiateAuthFlow $ authorizationKickoff
      Cli.ioE (readMVar authResultVar) \err -> do
        Cli.returnEarly (Output.CredentialFailureMsg err)
  let codeserverId = codeserverIdFromCodeserverURI host
  let creds = codeserverCredentials discoveryURI tokens
  liftIO (saveCredentials credentialManager codeserverId creds)
  Cli.respond Output.Success

-- | A server in the format expected for a Wai Application
-- This is a temporary server which is spun up only until we get a code back from the
-- auth server.
authTransferServer :: (Code -> Maybe URI -> (Response -> IO ResponseReceived) -> IO ResponseReceived) -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
authTransferServer callback req respond =
  case (requestMethod req, pathInfo req, getQueryParams req) of
    ("GET", ["redirect"], (Just code, maybeNextURI)) -> do
      callback code maybeNextURI respond
    _ -> respond (responseLBS status404 [] "Not Found")
  where
    getQueryParams req = do
      let code = join $ Prelude.lookup "code" (queryString req)
          nextURI = do
            nextBS <- join $ Prelude.lookup "next" (queryString req)
            parseURI (BSC.unpack nextBS)
       in (Text.decodeUtf8 <$> code, nextURI)

-- | Construct an authorization URL from the parameters required.
authURI :: URI -> String -> OAuthState -> PKCEChallenge -> URI
authURI authEndpoint redirectURI state challenge =
  authEndpoint
    & addQueryParam "state" state
    & addQueryParam "redirect_uri" (BSC.pack redirectURI)
    & addQueryParam "response_type" "code"
    & addQueryParam "scope" "openid cloud sync"
    & addQueryParam "client_id" ucmOAuthClientID
    & addQueryParam "code_challenge" challenge
    & addQueryParam "code_challenge_method" "S256"

addQueryParam :: ByteString -> ByteString -> URI -> URI
addQueryParam key val uri =
  let existingQuery = parseQuery $ BSC.pack (uriQuery uri)
      newParam = (key, Just val)
   in uri {uriQuery = BSC.unpack $ renderQuery True (existingQuery <> [newParam])}

generateParams :: MonadIO m => m (PKCEVerifier, PKCEChallenge, OAuthState)
generateParams = liftIO $ do
  verifier <- BE.convertToBase @ByteString BE.Base64URLUnpadded <$> getRandomBytes 50
  let digest = Crypto.hashWith Crypto.SHA256 verifier
  let challenge = BE.convertToBase BE.Base64URLUnpadded digest
  state <- BE.convertToBase @ByteString BE.Base64URLUnpadded <$> getRandomBytes 12
  pure (verifier, challenge, state)

-- | Exchange an authorization code for tokens.
exchangeCode ::
  MonadIO m =>
  HTTP.Manager ->
  URI ->
  Code ->
  PKCEVerifier ->
  String ->
  m (Either CredentialFailure Tokens)
exchangeCode httpClient tokenEndpoint code verifier redirectURI = liftIO $ do
  req <- HTTP.requestFromURI tokenEndpoint
  let addFormData =
        urlEncodedBody
          [ ("code", Text.encodeUtf8 code),
            ("code_verifier", verifier),
            ("grant_type", "authorization_code"),
            ("redirect_uri", BSC.pack redirectURI),
            ("client_id", ucmOAuthClientID)
          ]
  let fullReq = addFormData $ req {HTTP.method = "POST", HTTP.requestHeaders = [("Accept", "application/json")]}
  resp <- HTTP.httpLbs fullReq httpClient
  case HTTP.responseStatus resp of
    status
      | status < status300 -> do
          let respBytes = HTTP.responseBody resp
          pure $ case Aeson.eitherDecode @Tokens respBytes of
            Left err -> Left (InvalidTokenResponse tokenEndpoint (Text.pack err))
            Right a -> Right a
      | otherwise -> pure $ Left (InvalidTokenResponse tokenEndpoint $ "Received " <> tShow status <> " response from token endpoint")
