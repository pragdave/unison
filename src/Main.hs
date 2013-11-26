module Main where

import Unison.Syntax.Term
import Unison.Syntax.Var
import Unison.Syntax.Term.Examples

import Unison.Syntax.Type as T
import Unison.Type.Context as C

expr :: Term () () (Var ())
expr = identity

main :: IO ()
main = putStrLn (show expr)
