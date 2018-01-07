{-# LANGUAGE OverloadedStrings #-}
import Web.Scotty
import System.Environment

main :: IO ()
main = do
    env <- getEnvironment
    let port = maybe 3000 read (lookup "PORT" env)
    scotty port $ get "/" $ text "Phoque de Police"
