{-# LANGUAGE OverloadedStrings #-}

module Run
    ( run
    ) where

import System.IO.Error

import Data.Char
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as B

import Network.HTTP.Types
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp

import Types
import Run.UnixSocket
import Run.ModifiedTime

run :: OpenAt -> Bool -> IO ()
run openAt debug = do
    B.putStrLn $ mconcat ["Plate is opening at ", B.pack (show openAt), ".."]
    case openAt of
        OpenAtPort p -> Warp.runSettings (Warp.setPort p settings) app
        OpenAtUnixSocket s -> do
            sock <- unixSocket s
            Warp.runSettingsSocket settings sock app
  where
    settings = Warp.setFdCacheDuration (if debug then 0 else 60)
        Warp.defaultSettings

app :: Wai.Application
app req respond = do
    if isSafeURL $ Wai.rawPathInfo req
        then serveNormal req >>= respond
        else respond notFound

notFound :: Wai.Response
notFound = Wai.responseLBS status404
    [(hContentType, "text/plain")]
    "Page not found"

notModified :: Wai.Response
notModified = Wai.responseLBS status304 [] ""

serveNormal :: Wai.Request -> IO Wai.Response
serveNormal req
    | "/static/" `B.isPrefixOf` url = serveStatic
    | url == "/favicon.ico" = serve
        "image/vnd.microsoft.icon" "static/img/favicon.ico"
    | url == "/robots.txt" = serve
        "text/plain" "robots.txt"
    | url == "/" = serve htmlctype $ htmlpath "/index/"
    | "/" `B.isSuffixOf` url = serve htmlctype $ htmlpath url
    | otherwise = return notFound
  where
    url = Wai.rawPathInfo req
    htmlctype = "text/html; charset=utf-8"
    htmlpath path = "output" `mappend` B.init path `mappend` ".html"
    serveStatic
        | ".jpg"  `B.isSuffixOf` url = serveRelURL "image/jpeg"
        | ".png"  `B.isSuffixOf` url = serveRelURL "image/png"
        | ".svg"  `B.isSuffixOf` url = serveRelURL "image/svg+xml"
        | ".js"   `B.isSuffixOf` url = serveRelURL "application/javascript"
        | ".css"  `B.isSuffixOf` url = serveRelURL "text/css"
        | ".pdf"  `B.isSuffixOf` url = serveRelURL "application/pdf"
        | otherwise = return notFound
    serveRelURL ctype = serve ctype (B.drop 1 url)
    serve ctype path = ioMaybe (return notFound) (return . useMTime)
        (getMTime path)
      where
        useMTime mtime = case modifiedSince req mtime of
            NotModified -> notModified
            Modified -> Wai.responseFile status200
                [ (hContentType, ctype)
                , (hLastModified, formattedMTime mtime)
                ]
                (B.unpack path) Nothing

ioMaybe
    :: IO b         -- what to do on error
    -> (a -> IO b)  -- what to do on no error
    -> IO a         -- original action
    -> IO b
ioMaybe onError normally action = do
    tried <- tryIOError action
    case tried of
        Left _ -> onError
        Right v -> normally v

isSafeURL :: ByteString -> Bool
isSafeURL url = and
    [ B.all urlChar url
    , not $ "//" `B.isInfixOf` url
    , not $ "../" `B.isInfixOf` url
    , not $ ".." `B.isSuffixOf` url
    ]

urlChar :: Char -> Bool
urlChar c = or
    [ ord 'a' <= n && n <= ord 'z'
    , ord 'A' <= n && n <= ord 'Z'
    , ord '0' <= n && n <= ord '9'
    , c `B.elem` "-_./"
    ]
  where
    n = ord c