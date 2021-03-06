module Parse.Expression (term, typeAnnotation, definition, expr) where

import Control.Applicative ((<$>), (<*>))
import qualified Data.List as List
import Text.Parsec hiding (newline, spaces)
import Text.Parsec.Indent (block, withPos)

import qualified Parse.Binop as Binop
import Parse.Helpers
import qualified Parse.Helpers as Help
import qualified Parse.Literal as Literal
import qualified Parse.Pattern as Pattern
import qualified Parse.Type as Type

import qualified AST.Expression.General as E
import qualified AST.Expression.Source as Source
import qualified AST.Literal as L
import qualified AST.Pattern as P
import qualified AST.Variable as Var
import qualified Reporting.Annotation as A


--------  Basic Terms  --------

varTerm :: IParser Source.Expr'
varTerm =
  toVar <$> var <?> "variable"


toVar :: String -> Source.Expr'
toVar v =
  case v of
    "True" ->
        E.Literal (L.Boolean True)

    "False" ->
        E.Literal (L.Boolean False)

    _ ->
        E.rawVar v


accessor :: IParser Source.Expr'
accessor =
  do  (start, lbl, end) <- located (try (string "." >> rLabel))

      let ann value =
            A.at start end value

      return $
        E.Lambda
            (ann (P.Var "_"))
            (ann (E.Access (ann (E.rawVar "_")) lbl))


negative :: IParser Source.Expr'
negative =
  do  (start, nTerm, end) <-
          located (try (char '-' >> notFollowedBy (char '.' <|> char '-')) >> term)

      let ann e =
            A.at start end e

      return $
        E.Binop
          (Var.Raw "-")
          (ann (E.Literal (L.IntNum 0)))
          nTerm


--------  Complex Terms  --------

listTerm :: IParser Source.Expr'
listTerm =
    shader' <|> braces (try range <|> E.ExplicitList <$> commaSep expr)
  where
    range =
      do  lo <- expr
          padded (string "..")
          E.Range lo <$> expr

    shader' =
      do  pos <- getPosition
          let uid = show (sourceLine pos) ++ ":" ++ show (sourceColumn pos)
          (rawSrc, tipe) <- Help.shader
          return $ E.GLShader uid (filter (/='\r') rawSrc) tipe


parensTerm :: IParser Source.Expr
parensTerm =
  choice
    [ try (parens opFn)
    , parens (tupleFn <|> parened)
    ]
  where
    lambda start end x body =
        A.at start end (E.Lambda (A.at start end (P.Var x)) body)

    var start end x =
        A.at start end (E.rawVar x)

    opFn =
      do  (start, op, end) <- located anyOp
          return $
            lambda start end "x" $
              lambda start end "y" $
                A.at start end $
                  E.Binop (Var.Raw op) (var start end "x") (var start end "y")

    tupleFn =
      do  (start, commas, end) <-
              located (comma >> many (whitespace >> comma))

          let vars = map (('v':) . show) [ 0 .. length commas + 1 ]

          return $
            foldr
              (lambda start end)
              (A.at start end (E.tuple (map (var start end) vars)))
              vars

    parened =
      do  (start, expressions, end) <- located (commaSep expr)
          return $
            case expressions of
              [expression] ->
                  expression
              _ ->
                  A.at start end (E.tuple expressions)


recordTerm :: IParser Source.Expr
recordTerm =
  addLocation $
    brackets $ choice [ misc, record ]
  where
    field =
      do  label <- rLabel
          patterns <- spacePrefix Pattern.term
          padded equals
          body <- expr
          return (label, makeFunction patterns body)

    record =
      E.Record <$> commaSep field

    change =
      do  lbl <- rLabel
          padded (string "<-")
          (,) lbl <$> expr

    remove r =
      do  string "-"
          whitespace
          E.Remove r <$> rLabel

    insert r =
      do  string "|"
          whitespace
          E.Insert r <$> rLabel <*> (padded equals >> expr)

    modify r =
      do  string "|"
          whitespace
          E.Modify r <$> commaSep1 change

    misc =
      try $ do
        record <- addLocation (E.rawVar <$> rLabel)
        opt <- padded (optionMaybe (addLocation (remove record)))
        case opt of
          Just e@(A.A _ e') ->
              try (insert e) <|> return e'
          Nothing ->
              try (insert record) <|> try (modify record)


term :: IParser Source.Expr
term =
  addLocation (choice [ E.Literal <$> Literal.literal, listTerm, accessor, negative ])
    <|> accessible (addLocation varTerm <|> parensTerm <|> recordTerm)
    <?> "basic term (4, x, 'c', etc.)"


--------  Applications  --------

appExpr :: IParser Source.Expr
appExpr =
  do  t <- term
      ts <- constrainedSpacePrefix term $ \str ->
                if null str then notFollowedBy (char '-') else return ()
      return $
          case ts of
            [] -> t
            _  -> List.foldl' (\f x -> A.merge f x $ E.App f x) t ts


--------  Normal Expressions  --------

expr :: IParser Source.Expr
expr =
  addLocation (choice [ ifExpr, letExpr, caseExpr ])
    <|> lambdaExpr
    <|> binaryExpr
    <?> "an expression"


binaryExpr :: IParser Source.Expr
binaryExpr =
    Binop.binops appExpr lastExpr anyOp
  where
    lastExpr = addLocation (choice [ ifExpr, letExpr, caseExpr ])
            <|> lambdaExpr


ifExpr :: IParser Source.Expr'
ifExpr =
  do  try (reserved "if")
      whitespace
      normal <|> multiIf
  where
    normal =
      do  bool <- expr
          padded (reserved "then")
          thenBranch <- expr
          whitespace <?> "an 'else' branch"
          reserved "else" <?> "an 'else' branch"
          whitespace
          elseBranch <- expr
          return $ E.MultiIf
            [ (bool, thenBranch)
            , (A.sameAs elseBranch (E.Literal . L.Boolean $ True), elseBranch)
            ]

    multiIf =
        E.MultiIf <$> spaceSep1 iff
      where
        iff =
            do  string "|" ; whitespace
                b <- expr ; padded arrow
                (,) b <$> expr


lambdaExpr :: IParser Source.Expr
lambdaExpr =
  do  char '\\' <|> char '\x03BB' <?> "anonymous function"
      whitespace
      args <- spaceSep1 Pattern.term
      padded arrow
      body <- expr
      return (makeFunction args body)


caseExpr :: IParser Source.Expr'
caseExpr =
  do  try (reserved "case")
      e <- padded expr
      reserved "of"
      whitespace
      E.Case e <$> (with <|> without)
  where
    case_ =
      do  p <- Pattern.expr
          padded arrow
          (,) p <$> expr

    with =
      brackets (semiSep1 (case_ <?> "cases { x -> ... }"))

    without =
      block (do c <- case_ ; whitespace ; return c)


-- LET

letExpr :: IParser Source.Expr'
letExpr =
  do  try (reserved "let")
      whitespace
      defs <-
        block $
          do  def <- typeAnnotation <|> definition
              whitespace
              return def
      padded (reserved "in")
      E.Let defs <$> expr


-- TYPE ANNOTATION

typeAnnotation :: IParser Source.Def
typeAnnotation =
    addLocation (Source.TypeAnnotation <$> try start <*> Type.expr)
  where
    start =
      do  v <- lowVar <|> parens symOp
          padded hasType
          return v


-- DEFINITION

definition :: IParser Source.Def
definition =
  addLocation $
  withPos $
    do  (name:args) <- defStart
        padded equals
        body <- expr
        return . Source.Definition name $ makeFunction args body


makeFunction :: [P.RawPattern] -> Source.Expr -> Source.Expr
makeFunction args body@(A.A ann _) =
    foldr (\arg body' -> A.A ann $ E.Lambda arg body') body args


defStart :: IParser [P.RawPattern]
defStart =
    choice
      [ do  pattern <- try Pattern.term
            infics pattern <|> func pattern
      , do  opPattern <- addLocation (P.Var <$> parens symOp)
            func opPattern
      ]
      <?> "the definition of a variable (x = ...)"
  where
    func pattern =
        case pattern of
          A.A _ (P.Var _) ->
              (pattern:) <$> spacePrefix Pattern.term

          _ ->
              return [pattern]

    infics p1 =
      do  (start, o:p, end) <- try (whitespace >> located anyOp)
          p2 <- (whitespace >> Pattern.term)
          let opName =
                if o == '`' then takeWhile (/='`') p else o:p
          return [ A.at start end (P.Var opName), p1, p2 ]
