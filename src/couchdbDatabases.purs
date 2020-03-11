module Perspectives.Couchdb.Databases where

import Affjax (printResponseFormatError)
import Affjax (request, get, Request) as AJ
import Affjax.RequestBody as RequestBody
import Affjax.RequestHeader (RequestHeader(..))
import Affjax.ResponseFormat as ResponseFormat
import Affjax.ResponseHeader (ResponseHeader, name, value)
import Affjax.StatusCode (StatusCode(..))
import Control.Monad.Error.Class (class MonadError, catchError, throwError, try)
import Control.Monad.Except (runExcept)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Writer (WriterT, execWriterT, tell)
import Data.Argonaut (encodeJson, fromArray, fromObject, fromString)
import Data.Array (cons, elemIndex, find, null)
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.Generic.Rep (class Generic)
import Data.HTTP.Method (Method(..))
import Data.Map (fromFoldable, insert)
import Data.Maybe (Maybe(..), isJust)
import Data.MediaType (MediaType)
import Data.Newtype (unwrap)
import Data.String (toLower)
import Data.String.Regex (Regex, test)
import Data.String.Regex.Flags (noFlags)
import Data.String.Regex.Unsafe (unsafeRegex)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect.Aff (Milliseconds(..), delay, message)
import Effect.Aff.Class (liftAff)
import Effect.Exception (Error, error)
import Foreign (Foreign, MultipleErrors, F)
import Foreign.Class (class Decode, decode)
import Foreign.Generic (decodeJSON, defaultOptions, genericEncodeJSON)
import Foreign.Generic.Class (class GenericEncode)
import Foreign.Object (empty, insert, delete) as OBJ
import Foreign.Object (fromFoldable) as StrMap
import Perspectives.Couchdb (CouchdbStatusCodes, DBS, DeleteCouchdbDocument, DesignDocument(..), Key, Password, ReplicationDocument(..), SecurityDocument, User, View, ViewResult(..), ViewResultRow(..), DatabaseName, escapeCouchdbDocumentName, onAccepted, onAccepted', onCorrectCallAndResponse)
import Perspectives.CouchdbState (MonadCouchdb)
import Perspectives.Representation.Class.Cacheable (class Revision, Revision_)
import Perspectives.User (getCouchdbBaseURL, getUser, getCouchdbPassword)
import Prelude (Unit, bind, const, discard, pure, show, unit, ($), (*>), (/=), (<$>), (<>), (==))

type ID = String

-----------------------------------------------------------
-- QUALIFYREQUEST
-----------------------------------------------------------
-- | Does not modify the request when:
-- |  * the sessionCookie AVar is empty;
-- |  * the value of the sessionCookie AVar is "Browser" (we don't do Authentication Cookies on the browser, as it
-- |    handles them itself.)
-- | Otherwise, adds a Cookie header containing the cached cookie. This is a synchronous function.
qualifyRequest :: forall f a. AJ.Request a -> MonadCouchdb f (AJ.Request a)
qualifyRequest req@{headers} = do
  -- cookie <- tryReadSessionCookieValue
  cookie <- pure Nothing
  case cookie of
    (Just x) | x /= "Browser" -> pure $ req {headers = cons (RequestHeader "Cookie" x) headers}
    otherwise -> pure req

defaultPerspectRequest :: forall f. MonadCouchdb f (AJ.Request String)
defaultPerspectRequest = qualifyRequest
  { method: Left GET
  , url: "http://localhost:5984/"
  , headers: []
  , content: Nothing
  -- TODO. Zonder de credentials weer mee te sturen, ben je niet geauthenticeerd.
  , username: Nothing
  , password: Nothing
  , withCredentials: true
  , responseFormat: ResponseFormat.string
}

-----------------------------------------------------------
-- AUTHENTICATION
-- See: http://127.0.0.1:5984/_utils/docs/api/server/authn.html#api-auth-cookie
-----------------------------------------------------------
ensureAuthentication :: forall f a. MonadCouchdb f a -> MonadCouchdb f a
ensureAuthentication a = catchError a (const (requestAuthentication_ *> a))
  where
    isUnauthorised :: Error -> Maybe Unit
    isUnauthorised e = if message e == "UNAUTHORIZED" then Just unit else Nothing

requestAuthentication_ :: forall f. MonadCouchdb f Unit
requestAuthentication_ = do
  usr <- getUser
  pwd <- getCouchdbPassword
  base <- getCouchdbBaseURL
  (rq :: (AJ.Request String)) <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left POST, url = (base <> "_session"), content = Just $ RequestBody.json (fromObject (StrMap.fromFoldable [Tuple "name" (fromString usr), Tuple "password" (fromString pwd)]))}
  onAccepted res.status [200, 203] "requestAuthentication_" (pure unit)

-----------------------------------------------------------
-- CREATE, DELETE, DATABASE
-----------------------------------------------------------
databaseStatusCodes :: CouchdbStatusCodes
databaseStatusCodes = fromFoldable
  [ Tuple 400 "Bad AJ.Request. Invalid database name."
  , Tuple 401 "Unauthorized. CouchDB Server Administrator privileges required."]

databaseNameRegex :: Regex
databaseNameRegex = unsafeRegex "^[a-z_][a-z0-9_$()+/-]*$" noFlags

isValidCouchdbDatabaseName :: String -> Boolean
isValidCouchdbDatabaseName s = test databaseNameRegex s

-- Database names must comply to rules given in https://docs.couchdb.org/en/stable/api/database/common.html#db
createDatabase :: forall f. DatabaseName -> MonadCouchdb f Unit
createDatabase dbname = if isValidCouchdbDatabaseName dbname
  then ensureAuthentication do
    base <- getCouchdbBaseURL
    rq <- defaultPerspectRequest
    res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> dbname)}
    -- (res :: AJ.AffjaxResponse String) <- liftAff $ AJ.put' (base <> dbname) (Nothing :: Maybe String)
    liftAff $ onAccepted' createStatusCodes res.status [201] "createDatabase" $ pure unit
  else throwError $ error ("createDatabase: invalid name: " <> dbname)
  where
    createStatusCodes = insert 412 "Precondition failed. Database already exists."
      databaseStatusCodes

deleteDatabase :: forall f. DatabaseName -> MonadCouchdb f Unit
deleteDatabase dbname = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left DELETE, url = (base <> dbname)}
  -- liftAff $ AJ.put' (base <> dbname) (Nothing :: Maybe String)
  liftAff $ onAccepted' deleteStatusCodes res.status [200] "deleteDatabase" $ pure unit
  where
    deleteStatusCodes = insert 412 "Precondition failed. Database does not exist."
      databaseStatusCodes

-----------------------------------------------------------
-- CREATE, DELETE, USER
-----------------------------------------------------------
-- | Create a non-admin user.
createUser :: forall f. User -> Password -> Array Role -> MonadCouchdb f Unit
createUser user password roles = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  content <- pure (fromObject (StrMap.fromFoldable
    [ Tuple "name" (fromString user)
    , Tuple "password" (fromString password)
    , Tuple "roles" (fromArray (fromString <$> roles))
    , Tuple "type" (fromString "user")]))
  res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> "_users/org.couchdb.user:" <> user), content = Just $ RequestBody.json content}
  liftAff $ onAccepted res.status [200, 201] "createUser" $ pure unit

type Role = String

-----------------------------------------------------------
-- SET SECURITY DOCUMENT
-- See http://127.0.0.1:5984/_utils/docs/api/database/security.html#api-db-security
-----------------------------------------------------------
-- | Set the security document in the database.
setSecurityDocument :: forall f. DatabaseName -> SecurityDocument -> MonadCouchdb f Unit
setSecurityDocument db doc = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> db <> "/_security"), content = Just $ RequestBody.json (encodeJson doc)}
  liftAff $ onAccepted res.status [200, 201, 202] "setSecurityDocument" $ pure unit

-----------------------------------------------------------
-- GET/SET DESIGN DOCUMENT
-----------------------------------------------------------
-- | Get the design document from the database.
getDesignDocument :: forall f. DatabaseName -> DocumentName -> MonadCouchdb f (Maybe DesignDocument)
getDesignDocument db docname = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {url = (base <> db <> "/_design/" <> docname)}
  case res.status of
    StatusCode 200 -> Just <$> (onCorrectCallAndResponse "getDesignDocument" res.body \(a :: DesignDocument) -> pure unit)
    otherwise -> pure Nothing

-- | Set the design document in the database.
setDesignDocument :: forall f. DatabaseName -> DocumentName -> DesignDocument -> MonadCouchdb f Unit
setDesignDocument db docname doc@(DesignDocument{_rev}) = ensureAuthentication do
  base <- getCouchdbBaseURL
  rev <- pure $ case _rev of
    Nothing -> ""
    Just r -> ("?rev=" <> r)
  rq <- defaultPerspectRequest
  -- res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> db <> "/_design/" <> docname <> rev), content = Just $ RequestBody.string (unsafeStringify $ encode doc)}
  res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> db <> "/_design/" <> docname <> rev), content = Just $ RequestBody.json (encodeJson doc)}
  liftAff $ onAccepted res.status [200, 201, 202] "setDesignDocument" $ pure unit

type DocumentName = String

-----------------------------------------------------------
-- GET/SET REPLICATION DOCUMENT
-----------------------------------------------------------
-- {
--     "_id": "my_rep",
--     "source": "http://myserver.com/foo",
--     "target":  "http://user:pass@localhost:5984/bar",
--     "create_target":  true,
--     "continuous": true
-- }

getReplicationDocument :: forall f. DocumentName -> MonadCouchdb f (Maybe ReplicationDocument)
getReplicationDocument docname = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {url = (base <> "_replicator/" <> docname)}
  case res.status of
    StatusCode 200 -> Just <$> (onCorrectCallAndResponse "getReplicationDocument" res.body \(a :: ReplicationDocument) -> pure unit)
    otherwise -> pure Nothing

setReplicationDocument :: forall f. ReplicationDocument -> MonadCouchdb f Unit
setReplicationDocument rd@(ReplicationDocument{_id}) = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> "_replicator/" <> _id), content = Just $ RequestBody.json (encodeJson rd)}
  liftAff $ onAccepted res.status [200, 201, 202] "setReplicationDocument" $ pure unit

replicateContinuously :: forall f. String -> String -> String -> MonadCouchdb f Unit
replicateContinuously name source target = setReplicationDocument (ReplicationDocument
  { _id: name
  , source: source
  , target: target
  , create_target: false
  , continuous: true
  })

endReplication :: forall f. DatabaseName -> DatabaseName -> MonadCouchdb f Boolean
endReplication source target = deleteDocument_ "_replicator" (source <> "_" <> target)
-----------------------------------------------------------
-- VIEW
-----------------------------------------------------------
-- | A View is a javascript map function (possibly complemented by a reduce function, not implemented here).
-- | A View is serialised to a string and stored in a Design Document.
-- | We present functions here to
-- |  * create an empty design document with a views section
-- |  * add and delete a view to a design document
-- |  * add a view to named design document in a database.
-- | Obtain a stringified javascript function by importing it from javascript:
-- |  foreign import mapFunction :: String
-- | where the javascript module holds:
-- | exports.mapFunction = (function(doc) {emit(doc.id, doc.something)}).toString()
-- | VERY IMPORTANT: the function may not be defined with a name, i.e. this will fail:
-- | exports.mapFunction = myFunc.stringify()
-- | function myFunc(doc) {emit(doc.id, doc.something)}

defaultDesignDocumentWithViewsSection :: String -> DesignDocument
defaultDesignDocumentWithViewsSection n = DesignDocument
  { _id: "_design/" <> n
  , _rev: Nothing
  , views: OBJ.empty
}

type ViewName = String

addView :: DesignDocument -> ViewName -> View -> DesignDocument
addView (DesignDocument r@{views}) name view = DesignDocument r {views = OBJ.insert name view views}

removeView :: DesignDocument -> ViewName -> DesignDocument
removeView (DesignDocument r@{views}) name = DesignDocument r {views = OBJ.delete name views}

addViewToDatabase :: forall f. DatabaseName -> DocumentName -> ViewName -> View -> MonadCouchdb f Unit
addViewToDatabase db docname viewname view = do
  (mddoc :: Maybe DesignDocument) <- getDesignDocument db docname
  case mddoc of
    Nothing -> setDesignDocument db docname (addView (defaultDesignDocumentWithViewsSection docname) viewname view)
    Just ddoc -> setDesignDocument db docname (addView ddoc viewname view)

removeViewFromDatabase :: forall f. DatabaseName -> DocumentName -> ViewName -> MonadCouchdb f Unit
removeViewFromDatabase db docname viewname = do
  (mddoc:: Maybe DesignDocument) <- getDesignDocument db docname
  case mddoc of
    Nothing -> pure unit
    Just ddoc@(DesignDocument{_rev}) -> setDesignDocument db docname (removeView ddoc viewname)

-- | Get the view on the database. Notice that the type of the value in the result
-- | is parameterised and must be an instance of Decode.
getViewOnDatabase :: forall f value. Decode value => DatabaseName -> DocumentName -> ViewName -> Maybe Key -> MonadCouchdb f (Array value)
getViewOnDatabase db docname viewname mkey = do
  base <- getCouchdbBaseURL
  queryPart <- case mkey of
    Nothing -> pure ""
    Just k -> pure ("?key=\"" <> k <> "\"")
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {url = (base <> db <> "/_design/" <> docname <> "/_view/" <> viewname <> queryPart)}
  (ViewResult{rows}) <- onAccepted res.status [200] "getViewOnDatabase"
    (onCorrectCallAndResponse "getViewOnDatabase" res.body \(a :: (ViewResult Foreign)) -> pure unit)
  -- (\(ViewResultRow{value}) -> decode value) <$> rows
  (r :: F (Array value)) <- pure $ (traverse (\(ViewResultRow{value}) -> decode value) rows)
  case runExcept r of
    Left e -> throwError (error ("getViewOnDatabase: multiple errors: " <> show e))
    Right results -> pure results


-----------------------------------------------------------
-- ALLDBS
-----------------------------------------------------------
allDbs :: forall f. MonadCouchdb f (Array String)
allDbs = do
  base <- getCouchdbBaseURL
  res <- lift $ AJ.get ResponseFormat.string (base <> "_all_dbs")
  -- pure $ unwrap res.response
  case res.body of
    (Left r) -> throwError $ error ("allDbs: error in call: " <> printResponseFormatError r)
    (Right s) -> do
      (r :: Either MultipleErrors DBS) <- pure $ runExcept (decodeJSON s)
      case r of
        (Left e) -> throwError $ error ("allDbs: error in decoding result: " <> show e)
        (Right dbs) -> pure $ unwrap dbs

-----------------------------------------------------------
-- DOCUMENT EXISTS
-----------------------------------------------------------
documentExists :: forall f. ID -> MonadCouchdb f Boolean
documentExists url = do
  (rq :: (AJ.Request String)) <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left HEAD, url = url}
  case res.status of
    StatusCode 200 -> pure true
    StatusCode 304 -> pure true
    otherwise -> pure false

-----------------------------------------------------------
-- DOCUMENT VERSION
-----------------------------------------------------------
retrieveDocumentVersion :: forall f. ID -> MonadCouchdb f (Maybe String)
retrieveDocumentVersion url = do
  (rq :: (AJ.Request String)) <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left HEAD, url = url}
  case res.status of
    StatusCode 200 -> version res.headers
    StatusCode 304 -> version res.headers
    otherwise -> pure Nothing

-----------------------------------------------------------
-- ADD, GET DOCUMENT
-----------------------------------------------------------
-- | Add a document with a GenericEncode instance to a database.
addDocument :: forall d f rep. Generic d rep => GenericEncode rep => String -> d -> String -> MonadCouchdb f Unit
addDocument databaseName doc docName = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {method = Left PUT, url = (base <> databaseName <> "/" <> docName), content = Just $ RequestBody.string (genericEncodeJSON defaultOptions doc)}
  liftAff $ onAccepted res.status [200, 201, 202] "addDocument" $ pure unit

-- | Get a document with a GenericDecode instance from a database.
getDocument :: forall d f. Revision d => Decode d => String -> String -> MonadCouchdb f (Maybe d)
getDocument databaseName docname = ensureAuthentication do
  base <- getCouchdbBaseURL
  rq <- defaultPerspectRequest
  res <- liftAff $ AJ.request $ rq {url = (base <> databaseName <> "/" <> docname)}
  case res.status of
    StatusCode 200 -> Just <$> (onCorrectCallAndResponse "getDocument" res.body \(a :: d) -> pure unit)
    otherwise -> pure Nothing

-----------------------------------------------------------
-- DELETE DOCUMENT
-----------------------------------------------------------
deleteDocument :: forall f. ID -> Maybe String -> MonadCouchdb f Boolean
deleteDocument url version' = ensureAuthentication do
  mrev <- case version' of
    Nothing -> retrieveDocumentVersion url
    Just v -> pure $ Just v
  case mrev of
    Nothing -> pure false
    Just rev -> do
      (rq :: (AJ.Request String)) <- defaultPerspectRequest
      res <- liftAff $ AJ.request $ rq {method = Left DELETE, url = (url <> "?rev=" <> rev) }
      pure $ isJust (elemIndex res.status [StatusCode 200, StatusCode 304])

deleteDocument_ :: forall f. DatabaseName -> ID -> MonadCouchdb f Boolean
deleteDocument_ databasename docname = do
  base <- getCouchdbBaseURL
  deleteDocument (base <> databasename <> "/" <> docname) Nothing
-----------------------------------------------------------
-- ADD ATTACHMENT
-----------------------------------------------------------
-- | Tries to attach the attachment to all paths, attempts all paths and throws the failing ones.
addAttachmentInDatabases :: forall f. Array ID -> String -> String -> MediaType -> MonadCouchdb f Unit
addAttachmentInDatabases docPaths attachmentName attachment mimetype = do
  errs <- execWriterT (for_ docPaths \docPath -> tryToAttach docPath)
  if null errs
    then pure unit
    else throwError (error ("Could not attach: " <> show errs))
  where
    tryToAttach :: String -> WriterT (Array Error) (MonadCouchdb f) Unit
    tryToAttach docPath = do
      -- delay to give Couchdb 2.1.2 necessary breathing space.
      liftAff $ delay (Milliseconds 200.0)
      r <- try $ lift $ addAttachment docPath attachmentName attachment mimetype
      case r of
        Left e -> tell [e]
        Right _ -> pure unit

-- | docPath should be `databaseName/documentName`.
addAttachment :: forall f. ID -> String -> String -> MediaType -> MonadCouchdb f DeleteCouchdbDocument
addAttachment docPath attachmentName attachment mimetype = do
  base <- getCouchdbBaseURL
  (rq@({headers}) :: (AJ.Request String)) <- defaultPerspectRequest
  mrev <- retrieveDocumentVersion  (base <> docPath)
  case mrev of
    Nothing -> throwError (error ("addAttachment needs a document revision string for " <> docPath))
    Just rev -> do
      res <- liftAff $ AJ.request $ rq
        { method = Left PUT
        , url = base <> docPath <> "/" <> escapeCouchdbDocumentName attachmentName <> "?rev=" <> rev
        , headers = cons (ContentType mimetype) headers
        , content = Just (RequestBody.string attachment)
        }
      onAccepted res.status [200, 201, 202] "addAttachment"
          (onCorrectCallAndResponse "addAttachment" res.body \(a :: DeleteCouchdbDocument)-> pure unit)
      -- For uploading attachments, the same structure is returned as for deleting a document.

-----------------------------------------------------------
-- VERSION
-----------------------------------------------------------
-- | Read the version from the headers.
version :: forall m. MonadError Error m => Array ResponseHeader -> m Revision_
version headers =  case find (\rh -> toLower (name rh) == "etag") headers of
  Nothing -> throwError $ error ("Perspectives.Instances.version: retrieveDocumentVersion: couchdb returns no ETag header holding a document version number")
  (Just h) -> case runExcept $ decodeJSON (value h) of
    Left e -> pure Nothing
    Right v -> pure $ Just v
