{-# LANGUAGE RecordWildCards #-}

module Unison.PrintError where

import Control.Lens ((%~))
import Control.Lens.Tuple (_1, _2, _3)
import Data.List (find, intersperse)
import Data.List.Extra (nubOrd)
import qualified Data.List.NonEmpty as Nel
import qualified Data.Map as Map
import Data.Proxy
import Data.Sequence (Seq (..))
import qualified Data.Set as Set
import Data.Set.NonEmpty (NESet)
import qualified Data.Set.NonEmpty as NES
import qualified Data.Text as Text
import Data.Void (Void)
import qualified Text.Megaparsec as P
import qualified Unison.ABT as ABT
import Unison.Builtin.Decls (unitRef, pattern TupleType')
import qualified Unison.Codebase.Path as Path
import Unison.ConstructorReference (ConstructorReference, GConstructorReference (..))
import Unison.HashQualified (HashQualified)
import Unison.Kind (Kind)
import qualified Unison.Kind as Kind
import Unison.Name (Name)
import qualified Unison.Name as Name
import qualified Unison.Names as Names
import qualified Unison.Names.ResolutionResult as Names
import qualified Unison.NamesWithHistory as NamesWithHistory
import Unison.Parser.Ann (Ann (..))
import Unison.Prelude
import qualified Unison.PrettyPrintEnv as PPE
import qualified Unison.PrettyPrintEnv.Names as PPE
import qualified Unison.Reference as R
import Unison.Referent (Referent, pattern Ref)
import Unison.Result (Note (..))
import qualified Unison.Result as Result
import qualified Unison.Settings as Settings
import qualified Unison.Syntax.HashQualified as HQ (toString)
import qualified Unison.Syntax.Lexer as L
import qualified Unison.Syntax.Name as Name (toText)
import Unison.Syntax.NamePrinter (prettyHashQualified0)
import Unison.Syntax.Parser (Annotated, ann)
import qualified Unison.Syntax.Parser as Parser
import qualified Unison.Syntax.TermPrinter as TermPrinter
import qualified Unison.Term as Term
import Unison.Type (Type)
import qualified Unison.Type as Type
import qualified Unison.Typechecker.Context as C
import Unison.Typechecker.TypeError
import qualified Unison.Typechecker.TypeVar as TypeVar
import qualified Unison.UnisonFile.Error as UF
import Unison.Util.AnnotatedText (AnnotatedText)
import qualified Unison.Util.AnnotatedText as AT
import Unison.Util.ColorText (Color)
import qualified Unison.Util.ColorText as Color
import Unison.Util.Monoid (intercalateMap)
import Unison.Util.Pretty (ColorText, Pretty)
import qualified Unison.Util.Pretty as Pr
import Unison.Util.Range (Range (..), startingLine)
import Unison.Var (Var)
import qualified Unison.Var as Var

type Env = PPE.PrettyPrintEnv

pattern Code :: Color
pattern Code = Color.Blue

pattern Type1 :: Color
pattern Type1 = Color.HiBlue

pattern Type2 :: Color
pattern Type2 = Color.Green

pattern ErrorSite :: Color
pattern ErrorSite = Color.HiRed

pattern TypeKeyword :: Color
pattern TypeKeyword = Color.Yellow

pattern AbilityKeyword :: Color
pattern AbilityKeyword = Color.Green

pattern Identifier :: Color
pattern Identifier = Color.Bold

defaultWidth :: Pr.Width
defaultWidth = 60

-- Various links used in error messages, collected here for a quick overview
structuralVsUniqueDocsLink :: IsString a => Pretty a
structuralVsUniqueDocsLink = "https://www.unison-lang.org/learn/language-reference/unique-types/"

fromOverHere' ::
  Ord a =>
  String ->
  [Maybe (Range, a)] ->
  [Maybe (Range, a)] ->
  Pretty (AnnotatedText a)
fromOverHere' s spots0 removing =
  fromOverHere s (catMaybes spots0) (catMaybes removing)

fromOverHere ::
  Ord a => String -> [(Range, a)] -> [(Range, a)] -> Pretty (AnnotatedText a)
fromOverHere src spots0 removing =
  let spots = toList $ Set.fromList spots0 Set.\\ Set.fromList removing
   in case length spots of
        0 -> mempty
        1 -> "\n  from right here:\n\n" <> showSource src spots
        _ -> "\n  from these spots, respectively:\n\n" <> showSource src spots

showTypeWithProvenance ::
  (Var v, Annotated a, Ord style) =>
  Env ->
  String ->
  style ->
  Type v a ->
  Pretty (AnnotatedText style)
showTypeWithProvenance env src color typ =
  style color (renderType' env typ)
    <> ".\n"
    <> fromOverHere' src [styleAnnotated color typ] []

styleAnnotated :: Annotated a => sty -> a -> Maybe (Range, sty)
styleAnnotated sty a = (,sty) <$> rangeForAnnotated a

style :: s -> String -> Pretty (AnnotatedText s)
style sty str = Pr.lit . AT.annotate sty $ fromString str

stylePretty :: Color -> Pretty ColorText -> Pretty ColorText
stylePretty = Pr.map . AT.annotate

describeStyle :: Color -> Pretty ColorText
describeStyle ErrorSite = "in " <> style ErrorSite "red"
describeStyle Type1 = "in " <> style Type1 "blue"
describeStyle Type2 = "in " <> style Type2 "green"
describeStyle _ = ""

-- Render an informational typechecking note
renderTypeInfo ::
  forall v loc sty.
  (Var v, Annotated loc, Ord loc, Show loc) =>
  TypeInfo v loc ->
  Env ->
  Pretty (AnnotatedText sty)
renderTypeInfo i env = case i of
  TopLevelComponent {..} -> case definitions of
    [def] ->
      Pr.wrap "🌟 I found and typechecked a definition:" <> Pr.newline
        <> mconcat
          (renderOne def)
    [] -> mempty
    _ ->
      Pr.wrap "🎁 These mutually dependent definitions typechecked:"
        <> Pr.newline
        <> intercalateMap Pr.newline (foldMap ("\t" <>) . renderOne) definitions
  where
    renderOne :: IsString s => (v, Type v loc, RedundantTypeAnnotation) -> [s]
    renderOne (v, typ, _) =
      [fromString . Text.unpack $ Var.name v, " : ", renderType' env typ]

-- Render a type error
renderTypeError ::
  forall v loc.
  (Var v, Annotated loc, Ord loc, Show loc) =>
  TypeError v loc ->
  Env ->
  String ->
  Path.Absolute ->
  Pretty ColorText
renderTypeError e env src curPath = case e of
  BooleanMismatch {..} ->
    mconcat
      [ Pr.wrap $
          mconcat
            [ preamble,
              " ",
              style Type1 "Boolean",
              ", but this one is ",
              style Type2 (renderType' env foundType),
              ":"
            ],
        Pr.lineSkip,
        showSourceMaybes src [siteS],
        fromOverHere' src [typeS] [siteS],
        debugNoteLoc $
          mconcat
            [ "loc debug:",
              "\n  mismatchSite: ",
              annotatedToEnglish mismatchSite,
              "\n     foundType: ",
              annotatedToEnglish foundType,
              "\n"
            ],
        debugSummary note
      ]
    where
      siteS = styleAnnotated Type2 mismatchSite
      typeS = styleAnnotated Type2 foundType
      preamble = case getBooleanMismatch of
        CondMismatch ->
          "The condition for an "
            <> style ErrorSite "if"
            <> "-expression has to be"
        AndMismatch ->
          "The arguments to " <> style ErrorSite "&&" <> " have to be"
        OrMismatch ->
          "The arguments to " <> style ErrorSite "||" <> " have to be"
        GuardMismatch ->
          "The guard expression for a "
            <> style ErrorSite "match"
            <> "/"
            <> style ErrorSite "with"
            <> " has to be"
  ExistentialMismatch {..} ->
    mconcat
      [ Pr.lines
          [ Pr.wrap preamble,
            "",
            "Here, one   is:  " <> style Type1 (renderType' env expectedType),
            "and another is:  " <> style Type2 (renderType' env foundType),
            ""
          ],
        Pr.lineSkip,
        showSourceMaybes src [mismatchSiteS, expectedLocS],
        fromOverHere'
          src
          [expectedTypeS, mismatchedTypeS]
          [mismatchSiteS, expectedLocS],
        intLiteralSyntaxTip mismatchSite expectedType,
        debugNoteLoc $
          mconcat
            [ "\nloc debug:",
              "\n  mismatchSite: ",
              annotatedToEnglish mismatchSite,
              "\n     foundType: ",
              annotatedToEnglish foundType,
              "\n  expectedType: ",
              annotatedToEnglish expectedType,
              "\n   expectedLoc: ",
              annotatedToEnglish expectedLoc,
              "\n"
            ],
        debugSummary note
      ]
    where
      mismatchedTypeS = styleAnnotated Type2 foundType
      mismatchSiteS = styleAnnotated Type2 mismatchSite
      expectedTypeS = styleAnnotated Type1 expectedType
      expectedLocS = styleAnnotated Type1 expectedLoc
      preamble = case getExistentialMismatch of
        IfBody ->
          mconcat
            [ "The ",
              style ErrorSite "else",
              " clause of an ",
              style ErrorSite "if",
              " expression needs to have the same type as the ",
              style ErrorSite "then",
              " clause."
            ]
        ListBody -> "All the elements of a list need to have the same type."
        CaseBody ->
          mconcat
            [ "Each case of a ",
              style ErrorSite "match",
              "/",
              style ErrorSite "with",
              " expression ",
              "need to have the same type."
            ]
  NotFunctionApplication {..} ->
    mconcat
      [ "This looks like a function call, but with a ",
        style Type1 (renderType' env ft),
        " where the function should be.  Are you missing an operator?\n\n",
        annotatedAsStyle Type1 src f,
        debugSummary note
      ]
  FunctionApplication {..} ->
    let fte = Type.removePureEffects ft
        fteFreeVars = Set.map TypeVar.underlying $ ABT.freeVars fte
        showVar (v, _t) = Set.member v fteFreeVars
        solvedVars' = filter showVar solvedVars
     in mconcat
          [ Pr.lines
              [ Pr.wrap $
                  "The " <> ordinal argNum <> " argument to "
                    <> Pr.backticked (style ErrorSite (renderTerm env f)),
                "",
                "          has type:  " <> style Type2 (renderType' env foundType),
                "    but I expected:  " <> style Type1 (renderType' env expectedType),
                "",
                showSourceMaybes
                  src
                  [ (,Type1) <$> rangeForAnnotated expectedType,
                    (,Type2) <$> rangeForAnnotated foundType,
                    (,Type2) <$> rangeForAnnotated arg,
                    (,ErrorSite) <$> rangeForAnnotated f
                  ]
              ],
            intLiteralSyntaxTip arg expectedType,
            -- todo: factor this out and use in ExistentialMismatch and any other
            --       "recursive subtypes" situations
            case leafs of
              Nothing -> mempty
              Just (foundLeaf, expectedLeaf) ->
                Pr.lines
                  [ "",
                    "The mismatch is because these types differ:\n",
                    Pr.indentN 2 $ style Type2 (renderType' env foundLeaf),
                    Pr.indentN 2 $ style Type1 (renderType' env expectedLeaf),
                    ""
                  ]
                  <> showSourceMaybes
                    src
                    [ (,Type1) <$> rangeForAnnotated expectedLeaf,
                      (,Type2) <$> rangeForAnnotated foundLeaf
                    ],
            case solvedVars' of
              _ : _ ->
                let go :: (v, C.Type v loc) -> Pretty ColorText
                    go (v, t) =
                      mconcat
                        [ " ",
                          renderVar v,
                          " = ",
                          style ErrorSite (renderType' env t),
                          ", from here:\n\n",
                          showSourceMaybes
                            src
                            [(,ErrorSite) <$> rangeForAnnotated t],
                          "\n"
                        ]
                 in mconcat
                      [ "\n",
                        "because the ",
                        style ErrorSite (renderTerm env f),
                        " function has type",
                        "\n\n",
                        "  ",
                        renderType' env fte,
                        "\n\n",
                        "where:",
                        "\n\n",
                        mconcat (go <$> solvedVars')
                      ]
              [] -> mempty,
            debugNoteLoc
              . mconcat
              $ [ "\nloc debug:",
                  style ErrorSite "\n             f: ",
                  annotatedToEnglish f,
                  style Type2 "\n     foundType: ",
                  annotatedToEnglish foundType,
                  style Type1 "\n  expectedType: ",
                  annotatedToEnglish expectedType
                  -- , "\n   expectedLoc: ", annotatedToEnglish expectedLoc
                ],
            debugSummary note
          ]
  Mismatch {..} ->
    mconcat
      [ Pr.lines
          [ "I found a value  of type:  " <> style Type1 (renderType' env foundLeaf),
            "where I expected to find:  " <> style Type2 (renderType' env expectedLeaf)
          ],
        "\n\n",
        showSourceMaybes
          src
          [ -- these are overwriting the colored ranges for some reason?
            --   (,Color.ForceShow) <$> rangeForAnnotated mismatchSite
            -- , (,Color.ForceShow) <$> rangeForType foundType
            -- , (,Color.ForceShow) <$> rangeForType expectedType
            -- ,
            (,Type1) . startingLine <$> (rangeForAnnotated mismatchSite),
            (,Type2) <$> rangeForAnnotated expectedLeaf
          ],
        fromOverHere'
          src
          [styleAnnotated Type1 foundLeaf]
          [styleAnnotated Type2 expectedLeaf],
        unitHint,
        intLiteralSyntaxTip mismatchSite expectedType,
        debugNoteLoc
          . mconcat
          $ [ "\nloc debug:",
              "\n  mismatchSite: ",
              annotatedToEnglish mismatchSite,
              "\n     foundType: ",
              annotatedToEnglish foundType,
              "\n     foundLeaf: ",
              annotatedToEnglish foundLeaf,
              "\n  expectedType: ",
              annotatedToEnglish expectedType,
              "\n  expectedLeaf: ",
              annotatedToEnglish expectedLeaf,
              "\n"
            ],
        debugSummary note
      ]
    where
      unitHintMsg =
        "\nHint: Actions within a block must have type "
          <> style Type2 (renderType' env expectedLeaf)
          <> ".\n"
          <> "      Use "
          <> style Type1 "_ = <expr>"
          <> " to ignore a result."
      unitHint = if giveUnitHint then unitHintMsg else ""
      giveUnitHint = case expectedType of
        Type.Ref' u | u == unitRef -> case mismatchSite of
          Term.Let1Named' v _ _ -> Var.isAction v
          _ -> False
        _ -> False
  AbilityCheckFailure {..}
    | [tv@(Type.Var' ev)] <- ambient,
      ev `Set.member` foldMap Type.freeVars requested ->
        mconcat
          [ "I tried to infer a cyclic ability.",
            "\n\n",
            "The expression ",
            describeStyle ErrorSite,
            " was inferred to require the ",
            case length requested of
              1 -> "ability: "
              _ -> "abilities: ",
            "\n\n    {",
            commas (renderType' env) requested,
            "}",
            "\n\n",
            "where `",
            renderType' env tv,
            "` is its overall abilities.",
            "\n\n",
            "I need a type signature to help figure this out.",
            "\n\n",
            annotatedAsErrorSite src abilityCheckFailureSite,
            debugSummary note
          ]
  AbilityCheckFailure {..}
    | C.InSubtype {} :<| _ <- C.path note ->
        mconcat
          [ "The expression ",
            describeStyle ErrorSite,
            "\n\n",
            "              needs the abilities: {",
            commas (renderType' env) requested,
            "}\n",
            "  but was assumed to only require: {",
            commas (renderType' env) ambient,
            "}",
            "\n\n",
            "This is likely a result of using an un-annotated ",
            "function as an argument with concrete abilities. ",
            "Try adding an annotation to the function definition whose ",
            "body is red.",
            "\n\n",
            annotatedAsErrorSite src abilityCheckFailureSite,
            debugSummary note
          ]
  AbilityCheckFailure {..} ->
    mconcat
      [ "The expression ",
        describeStyle ErrorSite,
        " ",
        case toList requested of
          [] -> error "unpossible"
          [e] -> "needs the {" <> renderType' env e <> "} ability,"
          requested ->
            " needs these abilities: {"
              <> commas (renderType' env) requested
              <> "},",
        " but ",
        case toList ambient of
          [] -> "this location does not have access to any abilities."
          [e] ->
            "this location only has access to the {"
              <> renderType' env e
              <> "} ability,"
          ambient ->
            "this location only has access to these abilities: "
              <> "{"
              <> commas (renderType' env) ambient
              <> "}",
        "\n\n",
        annotatedAsErrorSite src abilityCheckFailureSite,
        debugSummary note
      ]
  AbilityEqFailure {..} ->
    mconcat
      [ "I found an ability mismatch when checking the expression ",
        describeStyle ErrorSite,
        "\n\n",
        showSourceMaybes
          src
          [ (,Type1) <$> rangeForAnnotated tlhs,
            (,Type2) <$> rangeForAnnotated trhs,
            (,ErrorSite) <$> rangeForAnnotated abilityCheckFailureSite
          ],
        "\n\n",
        Pr.wrap $
          mconcat
            [ "When trying to match ",
              style Type1 $ renderType' env tlhs,
              " with ",
              style Type2 $ renderType' env trhs,
              case (lhs, rhs) of
                ([], _) ->
                  mconcat
                    [ "the right hand side contained extra abilities: ",
                      style Type2 $ "{" <> commas (renderType' env) rhs <> "}"
                    ]
                (_, []) ->
                  mconcat
                    [ "the left hand side contained extra abilities: ",
                      style Type1 $ "{" <> commas (renderType' env) lhs <> "}"
                    ]
                _ ->
                  mconcat
                    [ " I could not make ",
                      style Type1 $ "{" <> commas (renderType' env) lhs <> "}",
                      " on the left compatible with ",
                      style Type2 $ "{" <> commas (renderType' env) rhs <> "}",
                      " on the right."
                    ]
            ],
        "\n\n",
        debugSummary note
      ]
  AbilityEqFailureFromAp {..} ->
    mconcat
      [ "I found an ability mismatch when checking the application",
        "\n\n",
        showSourceMaybes
          src
          [ (,Type1) <$> rangeForAnnotated expectedSite,
            (,Type2) <$> rangeForAnnotated mismatchSite
          ],
        "\n\n",
        Pr.wrap $
          mconcat
            [ "When trying to match ",
              style Type1 $ renderType' env tlhs,
              " with ",
              style Type2 $ renderType' env trhs,
              case (lhs, rhs) of
                ([], _) ->
                  mconcat
                    [ "the right hand side contained extra abilities: ",
                      style Type2 $ "{" <> commas (renderType' env) rhs <> "}"
                    ]
                (_, []) ->
                  mconcat
                    [ "the left hand side contained extra abilities: ",
                      style Type1 $ "{" <> commas (renderType' env) lhs <> "}"
                    ]
                _ ->
                  mconcat
                    [ " I could not make ",
                      style Type1 $ "{" <> commas (renderType' env) lhs <> "}",
                      " on the left compatible with ",
                      style Type2 $ "{" <> commas (renderType' env) rhs <> "}",
                      " on the right."
                    ]
            ],
        "\n\n",
        debugSummary note
      ]
  UnguardedLetRecCycle vs locs _ ->
    mconcat
      [ "These definitions depend on each other cyclically but aren't guarded ",
        "by a lambda: " <> intercalateMap ", " renderVar vs,
        "\n",
        showSourceMaybes src [(,ErrorSite) <$> rangeForAnnotated loc | loc <- locs]
      ]
  UnknownType {..} ->
    mconcat
      [ if ann typeSite == Intrinsic
          then "I don't know about the builtin type " <> style ErrorSite (renderVar unknownTypeV) <> ". "
          else
            if ann typeSite == External
              then "I don't know about the type " <> style ErrorSite (renderVar unknownTypeV) <> ". "
              else
                "I don't know about the type " <> style ErrorSite (renderVar unknownTypeV) <> ":\n"
                  <> annotatedAsErrorSite src typeSite,
        "Make sure it's imported and spelled correctly."
      ]
  UnknownTerm {..} ->
    let (correct, wrongTypes, wrongNames) =
          foldr sep id suggestions ([], [], [])
        sep (C.Suggestion name typ _ match) r =
          case match of
            C.Exact -> (_1 %~ ((name, typ) :)) . r
            C.WrongType -> (_2 %~ ((name, typ) :)) . r
            C.WrongName -> (_3 %~ ((name, typ) :)) . r
        libPath = Path.absoluteToPath' curPath Path.:> "lib"
     in mconcat
          [ "I couldn't find any definitions matching the name ",
            style ErrorSite (Var.nameStr unknownTermV),
            " inside the namespace ",
            prettyPath' (Path.absoluteToPath' curPath),
            "\n\n",
            annotatedAsErrorSite src termSite,
            "\n",
            Pr.hang
              "Some common causes of this error include:"
              ( Pr.bulleted
                  [ Pr.wrap "Your current namespace is too deep to contain the definition in its subtree",
                    Pr.wrap "The definition is part of a library which hasn't been added to this project"
                  ]
              )
              <> "\n\n"
              <> "To add a library to this project use the command: "
              <> Pr.backticked ("fork <.path.to.lib> " <> Pr.shown (libPath Path.:> "<libname>")),
            "\n\n",
            case expectedType of
              Type.Var' (TypeVar.Existential {}) -> "There are no constraints on its type."
              _ ->
                "Whatever it is, its type should conform to "
                  <> style Type1 (renderType' env expectedType)
                  <> ".",
            "\n\n",
            -- ++ showTypeWithProvenance env src Type1 expectedType
            case correct of
              [] -> case wrongTypes of
                [] -> case wrongNames of
                  [] -> mempty
                  wrongs -> formatWrongs wrongNameText wrongs
                wrongs -> formatWrongs wrongTypeText wrongs
              suggs ->
                mconcat
                  [ "I found some terms in scope that have matching names and types. ",
                    "Maybe you meant one of these:\n\n",
                    intercalateMap "\n" formatSuggestion suggs
                  ]
          ]
  DuplicateDefinitions {..} ->
    mconcat
      [ Pr.wrap $
          mconcat
            [ "I found",
              Pr.shown (length defns),
              names,
              "with multiple definitions:"
            ],
        Pr.lineSkip,
        Pr.spaced ((\(v, _locs) -> renderVar v) <$> defns),
        debugSummary note
      ]
    where
      names =
        case defns of
          _ Nel.:| [] -> "name"
          _ -> "names"
  Other (C.cause -> C.HandlerOfUnexpectedType loc typ) ->
    Pr.lines
      [ Pr.wrap "The handler used here",
        "",
        annotatedAsErrorSite src loc,
        Pr.wrap $
          "has type " <> stylePretty ErrorSite (Pr.group (renderType' env typ))
            <> "but I'm expecting a function of the form"
            <> Pr.group (Pr.blue (renderType' env exHandler) <> ".")
      ]
    where
      exHandler :: C.Type v loc
      exHandler =
        fmap (const loc) $
          Type.arrow
            ()
            ( Type.apps'
                (Type.ref () Type.effectRef)
                [Type.var () (Var.named "e"), Type.var () (Var.named "a")]
            )
            (Type.var () (Var.named "o"))
  Other (C.cause -> C.PatternArityMismatch loc typ num) ->
    Pr.lines
      [ Pr.wrap "This pattern has the wrong number of arguments",
        "",
        annotatedAsErrorSite src loc,
        "The constructor has type ",
        "",
        Pr.indentN 2 (stylePretty Type1 (Pr.group (renderType' env typ))),
        "",
        "but you supplied " <> (Pr.shown num) <> " arguments."
      ]
  Other note ->
    mconcat
      [ "Sorry, you hit an error we didn't make a nice message for yet.\n\n",
        "Here is a summary of the Note:\n",
        summary note
      ]
  where
    wrongTypeText pl =
      mconcat
        [ "I found ",
          pl "a term" "some terms",
          " in scope with ",
          pl "a " "",
          "matching name",
          pl "" "s",
          " but ",
          pl "a " "",
          "different type",
          pl "" "s",
          ". ",
          "If ",
          pl "this" "one of these",
          " is what you meant, try using the fully qualified name and I might ",
          "be able to give you a more illuminating error message: \n\n"
        ]
    wrongNameText pl =
      mconcat
        [ "I found ",
          pl "a term" "some terms",
          " in scope with ",
          pl "a " "",
          "matching type",
          pl "" "s",
          " but ",
          pl "a " "",
          "different name",
          pl "" "s",
          ". ",
          "Maybe you meant ",
          pl "this" "one of these",
          ":\n\n"
        ]
    formatSuggestion :: (Text, C.Type v loc) -> Pretty ColorText
    formatSuggestion (name, typ) =
      "  - " <> fromString (Text.unpack name) <> " : " <> renderType' env typ
    formatWrongs txt wrongs =
      let sz = length wrongs
          pl a b = if sz == 1 then a else b
       in mconcat [txt pl, intercalateMap "\n" formatSuggestion wrongs]
    ordinal :: (IsString s) => Int -> s
    ordinal n =
      fromString $
        show n ++ case last (show n) of
          '1' -> "st"
          '2' -> "nd"
          '3' -> "rd"
          _ -> "th"
    debugNoteLoc a = if Settings.debugNoteLoc then a else mempty
    debugSummary :: C.ErrorNote v loc -> Pretty ColorText
    debugSummary note =
      if Settings.debugNoteSummary then summary note else mempty
    summary :: C.ErrorNote v loc -> Pretty ColorText
    summary note =
      mconcat
        [ "\n",
          "  simple cause:\n",
          "    ",
          simpleCause (C.cause note),
          "\n"
          -- This can be very slow to print in large file. This was taking several minutes to print out the path in a file when the error occurred deep in the file after many other let bindings - stew
          --    , case toList (C.path note) of
          --      [] -> "  path: (empty)\n"
          --      l  -> "  path:\n" <> mconcat (simplePath <$> l)
        ]
    --   simplePath :: C.PathElement v loc -> Pretty ColorText
    --   simplePath e = "    " <> simplePath' e <> "\n"
    --   simplePath' :: C.PathElement v loc -> Pretty ColorText
    --   simplePath' = \case
    --     C.InSynthesize e -> "InSynthesize e=" <> renderTerm env e
    --     C.InEquate t1 t2 ->
    --       "InEquate t1=" <> renderType' env t1 <>
    --       ", t2=" <> renderType' env t2
    --     C.InSubtype t1 t2 ->
    --       "InSubtype t1=" <> renderType' env t1 <> ", t2=" <> renderType' env t2
    --     C.InCheck e t ->
    --       "InCheck e=" <> renderTerm env e <> "," <> " t=" <> renderType' env t
    --     C.InInstantiateL v t ->
    --       "InInstantiateL v=" <> renderVar v <> ", t=" <> renderType' env t
    --     C.InInstantiateR t v ->
    --       "InInstantiateR t=" <> renderType' env t <> " v=" <> renderVar v
    --     C.InSynthesizeApp t e n ->
    --       "InSynthesizeApp t="
    --         <> renderType' env t
    --         <> ", e="
    --         <> renderTerm env e
    --         <> ", n="
    --         <> fromString (show n)
    --     C.InFunctionCall vs f ft es ->
    --       "InFunctionCall vs=["
    --         <> commas renderVar vs
    --         <> "]"
    --         <> ", f="
    --         <> renderTerm env f
    --         <> ", ft="
    --         <> renderType' env ft
    --         <> ", es=["
    --         <> commas (renderTerm env) es
    --         <> "]"
    --     C.InIfCond        -> "InIfCond"
    --     C.InIfBody loc    -> "InIfBody thenBody=" <> annotatedToEnglish loc
    --     C.InAndApp        -> "InAndApp"
    --     C.InOrApp         -> "InOrApp"
    --     C.InVectorApp loc -> "InVectorApp firstTerm=" <> annotatedToEnglish loc
    --     C.InMatch     loc -> "InMatch firstBody=" <> annotatedToEnglish loc
    --     C.InMatchGuard    -> "InMatchGuard"
    --     C.InMatchBody     -> "InMatchBody"
    simpleCause :: C.Cause v loc -> Pretty ColorText
    simpleCause = \case
      C.TypeMismatch c ->
        mconcat ["TypeMismatch\n", "  context:\n", renderContext env c]
      C.HandlerOfUnexpectedType loc typ ->
        mconcat ["HandlerOfUnexpectedType\n", Pr.shown loc, "type:\n", renderType' env typ]
      C.IllFormedType c ->
        mconcat ["IllFormedType\n", "  context:\n", renderContext env c]
      C.UnguardedLetRecCycle vs _ts ->
        "Unguarded cycle of definitions: "
          <> foldMap renderVar vs
      C.UnknownSymbol loc v ->
        mconcat
          [ "UnknownSymbol: ",
            annotatedToEnglish loc,
            " " <> renderVar v,
            "\n\n",
            annotatedAsErrorSite src loc
          ]
      C.UnknownTerm loc v suggestions typ ->
        mconcat
          [ "UnknownTerm: ",
            annotatedToEnglish loc,
            " ",
            renderVar v,
            "\n\n",
            annotatedAsErrorSite src loc,
            "Suggestions: ",
            mconcat (renderSuggestion env <$> suggestions),
            "\n\n",
            "Type: ",
            renderType' env typ
          ]
      C.AbilityCheckFailure ambient requested c ->
        mconcat
          [ "AbilityCheckFailure: ",
            "ambient={",
            commas (renderType' env) ambient,
            "} requested={",
            commas (renderType' env) requested,
            "}\n",
            renderContext env c
          ]
      C.AbilityEqFailure left right c ->
        mconcat
          [ "AbilityEqFailure: ",
            "lhs={",
            commas (renderType' env) left,
            "} rhs={",
            commas (renderType' env) right,
            "}\n",
            renderContext env c
          ]
      C.EffectConstructorWrongArgCount e a r ->
        mconcat
          [ "EffectConstructorWrongArgCount:",
            "  expected=",
            (fromString . show) e,
            ", actual=",
            (fromString . show) a,
            ", reference=",
            showConstructor env r
          ]
      C.MalformedEffectBind ctorType ctorResult es ->
        mconcat
          [ "MalformedEffectBind: ",
            "  ctorType=",
            renderType' env ctorType,
            "  ctorResult=",
            renderType' env ctorResult,
            "  effects=",
            fromString (show es)
          ]
      C.PatternArityMismatch loc typ args ->
        mconcat
          [ "PatternArityMismatch:\n",
            "  loc=",
            annotatedToEnglish loc,
            "\n",
            "  typ=",
            renderType' env typ,
            "\n",
            "  args=",
            fromString (show args),
            "\n"
          ]
      C.DuplicateDefinitions vs ->
        let go :: (v, [loc]) -> Pretty (AnnotatedText a)
            go (v, locs) =
              "["
                <> renderVar v
                <> mconcat (intersperse " : " $ annotatedToEnglish <$> locs)
                <> "]"
         in "DuplicateDefinitions:" <> mconcat (go <$> Nel.toList vs)
      C.ConcatPatternWithoutConstantLength loc typ ->
        mconcat
          [ "ConcatPatternWithoutConstantLength:\n",
            "  loc=",
            annotatedToEnglish loc,
            "\n",
            "  typ=",
            renderType' env typ,
            "\n"
          ]
      C.DataEffectMismatch actual rf _ ->
        mconcat
          [ "DataEffectMismatch:\n",
            case actual of
              C.Data -> "  data type used as effect"
              C.Effect -> "  ability used as data type",
            "\n",
            "  reference=",
            showTypeRef env rf
          ]

renderCompilerBug ::
  (Var v, Annotated loc, Ord loc, Show loc) =>
  Env ->
  String ->
  C.CompilerBug v loc ->
  Pretty ColorText
renderCompilerBug env _src bug = mconcat $ case bug of
  C.UnknownDecl sort rf _decls ->
    [ "UnknownDecl:\n",
      case sort of
        C.Data -> "  data type"
        C.Effect -> "  ability",
      "\n",
      "  reerence = ",
      showTypeRef env rf
    ]
  C.UnknownConstructor sort (ConstructorReference rf i) _decl ->
    [ "UnknownConstructor:\n",
      case sort of
        C.Data -> "  data type\n"
        C.Effect -> "  ability\n",
      "  reference = ",
      showTypeRef env rf,
      "\n",
      "  constructor index = ",
      fromString (show i)
    ]
  C.UndeclaredTermVariable v ctx ->
    [ "UndeclaredTermVariable:\n  ",
      fromString $ renderVar' env ctx v
    ]
  C.RetractFailure elem ctx ->
    [ "RetractFailure:\n",
      fromString $ show elem,
      fromString $ show ctx
    ]
  C.EmptyLetRec tm ->
    [ "EmptyLetRec:\n",
      renderTerm env tm
    ]
  C.PatternMatchFailure -> ["PatternMatchFailure"]
  C.EffectConstructorHadMultipleEffects es ->
    [ "EffectConstructorHadMultipleEffects:\n  ",
      renderType' env es
    ]
  C.FreeVarsInTypeAnnotation vs ->
    [ "FreeVarsInTypeAnnotation:\n  ",
      intercalateMap ", " renderVar (toList vs)
    ]
  C.UnannotatedReference rf ->
    [ "UnannotatedReference:\n",
      showTypeRef env rf -- term/type shouldn't matter, since unknown
    ]
  C.MalformedPattern p ->
    [ "MalformedPattern:\n",
      fromString $ show p
    ]
  C.UnknownTermReference rf ->
    [ "UnknownTermReference:\n",
      showTermRef env (Ref rf)
    ]
  C.UnknownExistentialVariable v ctx ->
    [ "UnknownExistentialVariable:\n",
      fromString $ renderVar' env ctx v
    ]
  C.IllegalContextExtension ctx el str ->
    [ "IllegalContextExtension:\n",
      "  context:\n    ",
      fromString $ show ctx,
      "  element:\n    ",
      fromString $ show el,
      fromString str
    ]
  C.OtherBug str -> ["OtherBug:\n", fromString str]

renderContext ::
  (Var v, Ord loc) => Env -> C.Context v loc -> Pretty (AnnotatedText a)
renderContext env ctx@(C.Context es) =
  "  Γ\n    "
    <> intercalateMap "\n    " (showElem ctx . fst) (reverse es)
  where
    shortName :: (Var v, IsString loc) => v -> loc
    shortName = fromString . Text.unpack . Var.name
    showElem ::
      (Var v, Ord loc) =>
      C.Context v loc ->
      C.Element v loc ->
      Pretty (AnnotatedText a)
    showElem _ctx (C.Var v) = case v of
      TypeVar.Universal x -> "@" <> renderVar x
      e -> Pr.shown e
    showElem ctx (C.Solved _ v (Type.Monotype t)) =
      "'" <> shortName v <> " = " <> renderType' env (C.apply ctx t)
    showElem ctx (C.Ann v t) =
      shortName v <> " : " <> renderType' env (C.apply ctx t)
    showElem _ (C.Marker v) = "|" <> shortName v <> "|"

renderTerm :: (IsString s, Var v) => Env -> C.Term v loc -> s
renderTerm env e =
  let s = Color.toPlain $ TermPrinter.pretty' (Just 80) env (TypeVar.lowerTerm e)
   in if length s > Settings.renderTermMaxLength
        then fromString (take Settings.renderTermMaxLength s <> "...")
        else fromString s

-- | renders a type with no special styling
renderType' :: (IsString s, Var v) => Env -> Type v loc -> s
renderType' env typ =
  fromString . Pr.toPlain defaultWidth $ renderType env (const id) typ

-- | `f` may do some styling based on `loc`.
-- | You can pass `(const id)` if no styling is needed, or call `renderType'`.
renderType ::
  Var v =>
  Env ->
  (loc -> Pretty (AnnotatedText a) -> Pretty (AnnotatedText a)) ->
  Type v loc ->
  Pretty (AnnotatedText a)
renderType env f t = renderType0 env f (0 :: Int) (Type.removePureEffects t)
  where
    wrap :: (IsString a, Semigroup a) => a -> a -> Bool -> a -> a
    wrap start end test s = if test then start <> s <> end else s
    paren = wrap "(" ")"
    curly = wrap "{" "}"
    renderType0 env f p t = f (ABT.annotation t) $ case t of
      Type.Ref' r -> showTypeRef env r
      Type.Arrow' i (Type.Effect1' e o) ->
        paren (p >= 2) $ go 2 i <> " ->{" <> go 1 e <> "} " <> go 1 o
      Type.Arrow' i o -> paren (p >= 2) $ go 2 i <> " -> " <> go 1 o
      Type.Ann' t k -> paren True $ go 1 t <> " : " <> renderKind k
      TupleType' ts -> paren True $ commas (go 0) ts
      Type.Apps' (Type.Ref' (R.Builtin "Sequence")) [arg] ->
        "[" <> go 0 arg <> "]"
      Type.Apps' f' args -> paren (p >= 3) $ spaces (go 3) (f' : args)
      Type.Effects' es -> curly (p >= 3) $ commas (go 0) es
      Type.Effect' es t -> case es of
        [] -> go p t
        _ -> "{" <> commas (go 0) es <> "} " <> go 3 t
      Type.Effect1' e t -> paren (p >= 3) $ "{" <> go 0 e <> "}" <> go 3 t
      Type.ForallsNamed' vs body ->
        paren (p >= 1) $
          if not Settings.debugRevealForalls
            then go 0 body
            else "forall " <> spaces renderVar vs <> " . " <> go 1 body
      Type.Var' v -> renderVar v
      _ -> error $ "pattern match failure in PrintError.renderType " ++ show t
      where
        go = renderType0 env f

renderSuggestion ::
  (IsString s, Semigroup s, Var v) => Env -> C.Suggestion v loc -> s
renderSuggestion env sug =
  fromString (Text.unpack $ C.suggestionName sug) <> " : "
    <> renderType'
      env
      (C.suggestionType sug)

spaces :: (IsString a, Monoid a) => (b -> a) -> [b] -> a
spaces = intercalateMap " "

arrows :: (IsString a, Monoid a) => (b -> a) -> [b] -> a
arrows = intercalateMap " ->"

commas :: (IsString a, Monoid a) => (b -> a) -> [b] -> a
commas = intercalateMap ", "

renderVar :: (IsString a, Var v) => v -> a
renderVar = fromString . Text.unpack . Var.name

renderVar' :: (Var v, Annotated a) => Env -> C.Context v a -> v -> String
renderVar' env ctx v = case C.lookupSolved ctx v of
  Nothing -> "unsolved"
  Just t -> renderType' env $ Type.getPolytype t

prettyVar :: Var v => v -> Pretty ColorText
prettyVar = Pr.text . Var.name

renderKind :: Kind -> Pretty (AnnotatedText a)
renderKind Kind.Star = "*"
renderKind (Kind.Arrow k1 k2) = renderKind k1 <> " -> " <> renderKind k2

showTermRef :: IsString s => Env -> Referent -> s
showTermRef env r = fromString . HQ.toString $ PPE.termName env r

showTypeRef :: IsString s => Env -> R.Reference -> s
showTypeRef env r = fromString . HQ.toString $ PPE.typeName env r

-- todo: do something different/better if cid not found
showConstructor :: IsString s => Env -> ConstructorReference -> s
showConstructor env r =
  fromString . HQ.toString $
    PPE.patternName env r

styleInOverallType ::
  (Var v, Annotated a, Eq a) =>
  Env ->
  C.Type v a ->
  C.Type v a ->
  Color ->
  Pretty ColorText
styleInOverallType e overallType leafType c = renderType e f overallType
  where
    f loc s = if loc == ABT.annotation leafType then Color.style c <$> s else s

_posToEnglish :: IsString s => L.Pos -> s
_posToEnglish (L.Pos l c) =
  fromString $ "Line " ++ show l ++ ", Column " ++ show c

rangeForToken :: L.Token a -> Range
rangeForToken t = Range (L.start t) (L.end t)

rangeToEnglish :: IsString s => Range -> s
rangeToEnglish (Range (L.Pos l c) (L.Pos l' c')) =
  fromString $
    let showColumn = True
     in if showColumn
          then
            if l == l'
              then
                if c == c'
                  then "line " ++ show l ++ ", column " ++ show c
                  else "line " ++ show l ++ ", columns " ++ show c ++ "-" ++ show c'
              else
                "line "
                  ++ show l
                  ++ ", column "
                  ++ show c
                  ++ " through "
                  ++ "line "
                  ++ show l'
                  ++ ", column "
                  ++ show c'
          else
            if l == l'
              then "line " ++ show l
              else "lines " ++ show l ++ "—" ++ show l'

annotatedToEnglish :: (Annotated a, IsString s) => a -> s
annotatedToEnglish a = case ann a of
  Intrinsic -> "an intrinsic"
  External -> "an external"
  Ann start end -> rangeToEnglish $ Range start end

rangeForAnnotated :: Annotated a => a -> Maybe Range
rangeForAnnotated a = case ann a of
  Intrinsic -> Nothing
  External -> Nothing
  Ann start end -> Just $ Range start end

showLexerOutput :: Bool
showLexerOutput = False

renderNoteAsANSI ::
  (Var v, Annotated a, Show a, Ord a) =>
  Pr.Width ->
  Env ->
  String ->
  Path.Absolute ->
  Note v a ->
  String
renderNoteAsANSI w e s curPath n = Pr.toANSI w $ printNoteWithSource e s curPath n

renderParseErrorAsANSI :: Var v => Pr.Width -> String -> Parser.Err v -> String
renderParseErrorAsANSI w src = Pr.toANSI w . prettyParseError src

printNoteWithSource ::
  (Var v, Annotated a, Show a, Ord a) =>
  Env ->
  String ->
  Path.Absolute ->
  Note v a ->
  Pretty ColorText
printNoteWithSource env _s _curPath (TypeInfo n) = prettyTypeInfo n env
printNoteWithSource _env s _curPath (Parsing e) = prettyParseError s e
printNoteWithSource env s curPath (TypeError e) = prettyTypecheckError e env s curPath
printNoteWithSource _env _s _curPath (NameResolutionFailures _es) = undefined
printNoteWithSource _env s _curPath (UnknownSymbol v a) =
  fromString ("Unknown symbol `" ++ Text.unpack (Var.name v) ++ "`\n\n")
    <> annotatedAsErrorSite s a
printNoteWithSource env s _curPath (CompilerBug (Result.TypecheckerBug c)) =
  renderCompilerBug env s c
printNoteWithSource _env _s _curPath (CompilerBug c) =
  fromString $ "Compiler bug: " <> show c

_printPosRange :: String -> L.Pos -> L.Pos -> String
_printPosRange s (L.Pos startLine startCol) _end =
  -- todo: multi-line ranges
  -- todo: ranges
  _printArrowsAtPos s startLine startCol

_printArrowsAtPos :: String -> Int -> Int -> String
_printArrowsAtPos s line column =
  let lineCaret s i = s ++ if i == line then "\n" ++ columnCaret else ""
      columnCaret = replicate (column - 1) '-' ++ "^"
      source = unlines (uncurry lineCaret <$> lines s `zip` [1 ..])
   in source

-- Wow, epic view pattern for picking out a lexer error
pattern LexerError :: [L.Token L.Lexeme] -> L.Err -> Maybe (P.ErrorItem (L.Token L.Lexeme))
pattern LexerError ts e <- Just (P.Tokens (firstLexerError -> Just (ts, e)))

firstLexerError :: Foldable t => t (L.Token L.Lexeme) -> Maybe ([L.Token L.Lexeme], L.Err)
firstLexerError ts =
  find (const True) [(toList ts, e) | (L.payload -> L.Err e) <- toList ts]

prettyParseError ::
  forall v.
  Var v =>
  String ->
  Parser.Err v ->
  Pretty ColorText
prettyParseError s e =
  mconcat (fst <$> renderParseErrors s e) <> lexerOutput
  where
    lexerOutput :: Pretty (AnnotatedText a)
    lexerOutput =
      if showLexerOutput
        then "\nLexer output:\n" <> fromString (L.debugLex' s)
        else mempty

renderParseErrors ::
  forall v.
  Var v =>
  String ->
  Parser.Err v ->
  [(Pretty ColorText, [Range])]
renderParseErrors s = \case
  P.TrivialError _ (LexerError ts e) _ -> [(go e, ranges)]
    where
      ranges = rangeForToken <$> ts
      excerpt = showSource s ((\r -> (r, ErrorSite)) <$> ranges)
      go = \case
        L.UnexpectedDelimiter s ->
          "I found a " <> style ErrorSite (fromString s)
            <> " here, but I didn't see a list or tuple that it might be a separator for.\n\n"
            <> excerpt
        L.CloseWithoutMatchingOpen open close ->
          "I found a closing " <> style ErrorSite (fromString close)
            <> " here without a matching "
            <> style ErrorSite (fromString open)
            <> ".\n\n"
            <> excerpt
        L.InvalidWordyId _id ->
          Pr.lines
            [ "This identifier isn't valid syntax: ",
              "",
              excerpt,
              "Here's a few examples of valid syntax: "
                <> style Code "abba1', snake_case, Foo.zoink!, 🌻"
            ]
        L.ReservedWordyId _id ->
          Pr.lines
            [ "The identifier used here isn't allowed to be a reserved keyword: ",
              "",
              excerpt
            ]
        L.InvalidSymbolyId _id ->
          Pr.lines
            [ "This infix identifier isn't valid syntax: ",
              "",
              excerpt,
              "Here's a few valid examples: "
                <> style Code "++, Float./, `List.map`"
            ]
        L.ReservedSymbolyId _id ->
          Pr.lines
            [ "This identifier is reserved by Unison and can't be used as an operator: ",
              "",
              excerpt
            ]
        L.InvalidBytesLiteral bs ->
          Pr.lines
            [ "This bytes literal isn't valid syntax: " <> style ErrorSite (fromString bs),
              "",
              excerpt,
              Pr.wrap $
                "I was expecting an even number of hexidecimal characters"
                  <> "(one of"
                  <> Pr.group (style Code "0123456789abcdefABCDEF" <> ")")
                  <> "after the"
                  <> Pr.group (style ErrorSite "0xs" <> ".")
            ]
        L.InvalidHexLiteral ->
          Pr.lines
            [ "This number isn't valid syntax: ",
              "",
              excerpt,
              Pr.wrap $
                "I was expecting only hexidecimal characters"
                  <> "(one of"
                  <> Pr.group (style Code "0123456789abcdefABCDEF" <> ")")
                  <> "after the"
                  <> Pr.group (style ErrorSite "0x" <> ".")
            ]
        L.InvalidOctalLiteral ->
          Pr.lines
            [ "This number isn't valid syntax: ",
              "",
              excerpt,
              Pr.wrap $
                "I was expecting only octal characters"
                  <> "(one of"
                  <> Pr.group (style Code "01234567" <> ")")
                  <> "after the"
                  <> Pr.group (style ErrorSite "0o" <> ".")
            ]
        L.InvalidShortHash h ->
          Pr.lines
            [ "Invalid hash: " <> style ErrorSite (fromString h),
              "",
              excerpt
            ]
        L.Both e1 e2 -> Pr.lines [go e1, "", go e2]
        L.UnknownLexeme -> Pr.lines ["I couldn't parse this.", "", excerpt]
        L.MissingFractional n ->
          Pr.lines
            [ "This number isn't valid syntax: ",
              "",
              excerpt,
              Pr.wrap $
                "I was expecting some digits after the '.',"
                  <> "for example: "
                  <> style Code (n <> "0")
                  <> "or"
                  <> Pr.group (style Code (n <> "1e37") <> ".")
            ]
        L.MissingExponent n ->
          Pr.lines
            [ "This number isn't valid syntax: ",
              "",
              excerpt,
              Pr.wrap $
                "I was expecting some digits for the exponent,"
                  <> "for example: "
                  <> Pr.group (style Code (n <> "37") <> ".")
            ]
        L.TextLiteralMissingClosingQuote _txt ->
          Pr.lines
            [ "This text is missing a closing quote:",
              "",
              excerpt
            ]
        L.InvalidEscapeCharacter c ->
          Pr.lines
            [ "This isn't a valid escape character: " <> style ErrorSite [c],
              "",
              excerpt,
              "",
              "I only know about the following escape characters:",
              "",
              let s ch = style Code (fromString $ "\\" <> [ch])
               in Pr.indentN 2 $ intercalateMap "," s (fst <$> L.escapeChars)
            ]
        L.LayoutError ->
          Pr.lines
            [ "I found an indentation error somewhere in here:",
              "",
              excerpt
            ]
        L.Opaque msg -> style ErrorSite msg
  P.TrivialError errOffset unexpected expected ->
    let (src, ranges) = case unexpected of
          Just (P.Tokens (toList -> ts)) -> case ts of
            [] -> (mempty, [])
            _ ->
              let rs = rangeForToken <$> ts
               in (showSource s $ (\r -> (r, ErrorSite)) <$> rs, rs)
          _ -> mempty
        -- Same error that we just pattern matched on, but with a different error component (here Void) - we need one
        -- with a ShowErrorComponent instance, which our error type doesn't have.
        sameErr :: P.ParseError Parser.Input Void
        sameErr = P.TrivialError errOffset unexpected expected
     in [(fromString (P.parseErrorPretty sameErr) <> src, ranges)]
  P.FancyError _sp fancyErrors ->
    (go' <$> Set.toList fancyErrors)
  where
    go' :: P.ErrorFancy (Parser.Error v) -> (Pretty ColorText, [Range])
    go' (P.ErrorFail s) =
      ("The parser failed with this message:\n" <> fromString s, [])
    go' (P.ErrorIndentation ordering indent1 indent2) =
      let ranges = [] -- TODO: determine the source location from the offset position, which is the token offset maybe?
       in ( mconcat
              [ "The parser was confused by the indentation.\n",
                "It was expecting the reference level (",
                fromString (show indent1),
                ")\nto be ",
                fromString (show ordering),
                " than/to the actual level (",
                fromString (show indent2),
                ").\n"
              ],
            ranges
          )
    go' (P.ErrorCustom e) = go e
    errorVar v = style ErrorSite . fromString . Text.unpack $ Var.name v
    go :: Parser.Error v -> (Pretty ColorText, [Range])
    -- UseInvalidPrefixSuffix (Either (L.Token Name) (L.Token Name)) (Maybe [L.Token Name])
    go (Parser.PatternArityMismatch expected actual loc) = (msg, ranges)
      where
        ranges = maybeToList $ rangeForAnnotated loc
        msg =
          Pr.indentN 2 . Pr.callout "😶" $
            Pr.lines
              [ Pr.wrap $
                  "Not all the branches of this pattern matching have"
                    <> "the same number of arguments. I was assuming they'd all have "
                    <> Pr.hiBlue (Pr.shown expected)
                    <> "arguments (based on the previous patterns)"
                    <> "but this one has "
                    <> Pr.hiRed (Pr.shown actual)
                    <> "arguments:",
                annotatedAsErrorSite s loc
              ]
    go (Parser.FloatPattern loc) = (msg, ranges)
      where
        ranges = maybeToList $ rangeForAnnotated loc
        msg =
          Pr.indentN 2 . Pr.callout "😶" $
            Pr.lines
              [ Pr.wrap $
                  "Floating point pattern matching is disallowed. Instead,"
                    <> "it is recommended to test that a value is within"
                    <> "an acceptable error bound of the expected value.",
                annotatedAsErrorSite s loc
              ]
    go (Parser.UseEmpty tok) = (msg, ranges)
      where
        ranges = [rangeForToken tok]
        msg =
          Pr.indentN 2 . Pr.callout "😶" $
            Pr.lines
              [ Pr.wrap $ "I was expecting something after the " <> Pr.hiRed "use" <> "keyword",
                "",
                tokenAsErrorSite s tok,
                useExamples
              ]
    go (Parser.UseInvalidPrefixSuffix prefix suffix) = (msg', ranges)
      where
        msg' :: Pretty ColorText
        msg' = Pr.indentN 2 . Pr.blockedCallout . Pr.lines $ msg
        (msg, ranges) = case (prefix, suffix) of
          (Left tok, Just _) ->
            ( [ Pr.wrap "The first argument of a `use` statement can't be an operator name:",
                "",
                tokenAsErrorSite s tok,
                useExamples
              ],
              [rangeForToken tok]
            )
          (tok0, Nothing) ->
            let tok = either id id tok0
                ranges = [rangeForToken tok]
                txts =
                  [ Pr.wrap $ "I was expecting something after " <> Pr.hiRed "here:",
                    "",
                    tokenAsErrorSite s tok,
                    case Name.parent (L.payload tok) of
                      Nothing -> useExamples
                      Just parent ->
                        Pr.wrap $
                          "You can write"
                            <> Pr.group
                              ( Pr.blue $
                                  "use " <> Pr.text (Name.toText (Name.makeRelative parent)) <> " "
                                    <> Pr.text (Name.toText (Name.unqualified (L.payload tok)))
                              )
                            <> "to introduce "
                            <> Pr.backticked (Pr.text (Name.toText (Name.unqualified (L.payload tok))))
                            <> "as a local alias for "
                            <> Pr.backticked (Pr.text (Name.toText (L.payload tok)))
                  ]
             in (txts, ranges)
          (Right tok, _) ->
            ( [ -- this is unpossible but rather than bomb, nice msg
                "You found a Unison bug 🐞  here:",
                "",
                tokenAsErrorSite s tok,
                Pr.wrap $
                  "This looks like a valid `use` statement,"
                    <> "but the parser didn't recognize it. This is a Unison bug."
              ],
              [rangeForToken tok]
            )
    go (Parser.DisallowedAbsoluteName t) = (msg, ranges)
      where
        ranges = [rangeForToken t]
        msg :: Pretty ColorText
        msg =
          Pr.indentN 2 $
            Pr.fatalCallout $
              Pr.lines
                [ Pr.wrap $
                    "I don't currently support creating definitions that start with"
                      <> Pr.group (Pr.blue "'.'" <> ":"),
                  "",
                  tokenAsErrorSite s t,
                  Pr.wrap $ "Use " <> Pr.blue "help messages.disallowedAbsolute" <> "to learn more.",
                  ""
                ]
    go (Parser.DuplicateTypeNames ts) = (intercalateMap "\n\n" showDup ts, ranges)
      where
        ranges = ts >>= snd >>= toList . rangeForAnnotated
        showDup (v, locs) =
          "I found multiple types with the name " <> errorVar v <> ":\n\n"
            <> annotatedsStartingLineAsStyle ErrorSite s locs
    go (Parser.DuplicateTermNames ts) =
      (Pr.fatalCallout $ intercalateMap "\n\n" showDup ts, ranges)
      where
        ranges = ts >>= snd >>= toList . rangeForAnnotated
        showDup (v, locs) =
          Pr.lines
            [ Pr.wrap $
                "I found multiple bindings with the name " <> Pr.group (errorVar v <> ":"),
              annotatedsStartingLineAsStyle ErrorSite s locs
            ]
    go (Parser.TypeDeclarationErrors es) =
      let unknownTypes = [(v, a) | UF.UnknownType v a <- es]
          dupDataAndAbilities = [(v, a, a2) | UF.DupDataAndAbility v a a2 <- es]
          allAnns = (snd <$> unknownTypes) <> (foldMap (\(_, a1, a2) -> [a1, a2]) dupDataAndAbilities)
          allRanges = allAnns >>= maybeToList . rangeForAnnotated
          unknownTypesMsg =
            mconcat
              [ "I don't know about the type(s) ",
                intercalateMap ", " errorVar (nubOrd $ fst <$> unknownTypes),
                ":\n\n",
                annotatedsAsStyle ErrorSite s (snd <$> unknownTypes)
              ]
          dupDataAndAbilitiesMsg = intercalateMap "\n\n" dupMsg dupDataAndAbilities
          dupMsg (v, a, a2) =
            mconcat
              [ "I found two types called " <> errorVar v <> ":",
                "\n\n",
                annotatedsStartingLineAsStyle ErrorSite s [a, a2]
              ]
          msgs =
            if null unknownTypes
              then dupDataAndAbilitiesMsg
              else
                if null dupDataAndAbilities
                  then unknownTypesMsg
                  else unknownTypesMsg <> "\n\n" <> dupDataAndAbilitiesMsg
       in (msgs, allRanges)
    go (Parser.DidntExpectExpression _tok (Just t@(L.payload -> L.SymbolyId "::" Nothing))) =
      let msg =
            mconcat
              [ "This looks like the start of an expression here but I was expecting a binding.",
                "\nDid you mean to use a single " <> style Code ":",
                " here for a type signature?",
                "\n\n",
                tokenAsErrorSite s t
              ]
       in (msg, [rangeForToken t])
    go (Parser.DidntExpectExpression tok _nextTok) =
      let msg =
            mconcat
              [ "This looks like the start of an expression here \n\n",
                tokenAsErrorSite s tok,
                "\nbut at the file top-level, I expect one of the following:",
                "\n",
                "\n  - A binding, like " <> t <> style Code " = 42" <> " OR",
                "\n                    " <> t <> style Code " : Nat",
                "\n                    " <> t <> style Code " = 42",
                "\n  - A watch expression, like " <> style Code "> " <> t
                  <> style
                    Code
                    " + 1",
                "\n  - An `ability` declaration, like "
                  <> style Code "unique ability Foo where ...",
                "\n  - A `type` declaration, like "
                  <> style Code "structural type Optional a = None | Some a",
                "\n"
              ]
       in (msg, [rangeForToken tok])
      where
        t = style Code (fromString (P.showTokens (Proxy @[L.Token L.Lexeme]) (pure tok)))
    go (Parser.ExpectedBlockOpen blockName tok@(L.payload -> L.Close)) =
      let msg =
            mconcat
              [ "I was expecting an indented block following the "
                  <> "`"
                  <> fromString blockName
                  <> "` keyword\n",
                "but instead found an outdent:\n\n",
                tokenAsErrorSite s tok -- todo: @aryairani why is this displaying weirdly?
              ]
       in (msg, [rangeForToken tok])
    go (Parser.ExpectedBlockOpen blockName tok) =
      let msg =
            mconcat
              [ "I was expecting an indented block following the "
                  <> "`"
                  <> fromString blockName
                  <> "` keyword\n",
                "but instead found this token:\n",
                tokenAsErrorSite s tok
              ]
       in (msg, [rangeForToken tok])
    go (Parser.SignatureNeedsAccompanyingBody tok) =
      let msg =
            mconcat
              [ "You provided a type signature, but I didn't find an accompanying\n",
                "binding after it.  Could it be a spelling mismatch?\n",
                tokenAsErrorSite s tok
              ]
       in (msg, [rangeForToken tok])
    go (Parser.EmptyBlock tok) =
      let msg =
            mconcat
              [ "I expected a block after this (",
                describeStyle ErrorSite,
                "), ",
                "but there wasn't one.  Maybe check your indentation:\n",
                tokenAsErrorSite s tok
              ]
       in (msg, [rangeForToken tok])
    go (Parser.EmptyMatch tok) =
      let msg =
            Pr.indentN 2 . Pr.callout "😶" $
              Pr.lines
                [ Pr.wrap
                    ( "I expected some patterns after a "
                        <> style ErrorSite "match"
                        <> "/"
                        <> style ErrorSite "with"
                        <> " or cases but I didn't find any."
                    ),
                  "",
                  tokenAsErrorSite s tok
                ]
       in (msg, [rangeForToken tok])
    go (Parser.EmptyWatch tok) =
      let msg =
            Pr.lines
              [ "I expected a non-empty watch expression and not just \">\"",
                "",
                annotatedAsErrorSite s tok
              ]
       in (msg, maybeToList $ rangeForAnnotated tok)
    go (Parser.UnknownAbilityConstructor tok _referents) = (unknownConstructor "ability" tok, [rangeForToken tok])
    go (Parser.UnknownDataConstructor tok _referents) = (unknownConstructor "data" tok, [rangeForToken tok])
    go (Parser.UnknownId tok referents references) =
      let msg =
            Pr.lines
              [ if missing
                  then "I couldn't resolve the reference " <> style ErrorSite (HQ.toString (L.payload tok)) <> "."
                  else "The reference " <> style ErrorSite (HQ.toString (L.payload tok)) <> " was ambiguous.",
                "",
                tokenAsErrorSite s $ HQ.toString <$> tok,
                if missing
                  then "Make sure it's spelled correctly."
                  else "Try hash-qualifying the term you meant to reference."
              ]
       in (msg, [rangeForToken tok])
      where
        missing = Set.null referents && Set.null references
    go (Parser.UnknownTerm tok referents) =
      let msg =
            Pr.lines
              [ if Set.null referents
                  then "I couldn't find a term for " <> style ErrorSite (HQ.toString (L.payload tok)) <> "."
                  else "The term reference " <> style ErrorSite (HQ.toString (L.payload tok)) <> " was ambiguous.",
                "",
                tokenAsErrorSite s $ HQ.toString <$> tok,
                if missing
                  then "Make sure it's spelled correctly."
                  else "Try hash-qualifying the term you meant to reference."
              ]
       in (msg, [rangeForToken tok])
      where
        missing = Set.null referents
    go (Parser.UnknownType tok referents) =
      let msg =
            Pr.lines
              [ if Set.null referents
                  then "I couldn't find a type for " <> style ErrorSite (HQ.toString (L.payload tok)) <> "."
                  else "The type reference " <> style ErrorSite (HQ.toString (L.payload tok)) <> " was ambiguous.",
                "",
                tokenAsErrorSite s $ HQ.toString <$> tok,
                if missing
                  then "Make sure it's spelled correctly."
                  else "Try hash-qualifying the type you meant to reference."
              ]
       in (msg, [rangeForToken tok])
      where
        missing = Set.null referents
    go (Parser.ResolutionFailures failures) =
      -- TODO: We should likely output separate error messages, one for each resolution
      -- failure. This would involve adding a separate codepath for LSP error messages.
      let ranges = catMaybes (rangeForAnnotated . Names.getAnnotation <$> failures)
       in (Pr.border 2 . prettyResolutionFailures s $ failures, ranges)
    go (Parser.MissingTypeModifier keyword name) =
      let msg =
            Pr.lines
              [ Pr.wrap $
                  "I expected to see `structural` or `unique` at the start of this line:",
                "",
                tokensAsErrorSite s [void keyword, void name],
                Pr.wrap $
                  "Learn more about when to use `structural` vs `unique` in the Unison Docs: "
                    <> structuralVsUniqueDocsLink
              ]
       in (msg, rangeForToken <$> [void keyword, void name])

    unknownConstructor ::
      String -> L.Token (HashQualified Name) -> Pretty ColorText
    unknownConstructor ctorType tok =
      Pr.lines
        [ (Pr.wrap . mconcat)
            [ "I don't know about any ",
              fromString ctorType,
              " constructor named ",
              Pr.group
                ( stylePretty ErrorSite (prettyHashQualified0 (L.payload tok))
                    <> "."
                ),
              "Maybe make sure it's correctly spelled and that you've imported it:"
            ],
          "",
          tokenAsErrorSite s tok
        ]

annotatedAsErrorSite ::
  Annotated a => String -> a -> Pretty ColorText
annotatedAsErrorSite = annotatedAsStyle ErrorSite

annotatedAsStyle ::
  (Ord style, Annotated a) =>
  style ->
  String ->
  a ->
  Pretty (AnnotatedText style)
annotatedAsStyle style s ann =
  showSourceMaybes s [(,style) <$> rangeForAnnotated ann]

annotatedsAsErrorSite :: (Annotated a) => String -> [a] -> Pretty ColorText
annotatedsAsErrorSite = annotatedsAsStyle ErrorSite

annotatedsAsStyle :: (Annotated a) => Color -> String -> [a] -> Pretty ColorText
annotatedsAsStyle style src as =
  showSourceMaybes src [(,style) <$> rangeForAnnotated a | a <- as]

annotatedsStartingLineAsStyle ::
  (Annotated a) => Color -> String -> [a] -> Pretty ColorText
annotatedsStartingLineAsStyle style src as =
  showSourceMaybes
    src
    [(,style) <$> (startingLine <$> rangeForAnnotated a) | a <- as]

tokenAsErrorSite :: String -> L.Token a -> Pretty ColorText
tokenAsErrorSite src tok = showSource1 src (rangeForToken tok, ErrorSite)

tokensAsErrorSite :: String -> [L.Token a] -> Pretty ColorText
tokensAsErrorSite src ts =
  showSource src [(rangeForToken t, ErrorSite) | t <- ts]

showSourceMaybes ::
  Ord a => String -> [Maybe (Range, a)] -> Pretty (AnnotatedText a)
showSourceMaybes src annotations = showSource src $ catMaybes annotations

showSource :: Ord a => String -> [(Range, a)] -> Pretty (AnnotatedText a)
showSource src annotations =
  Pr.lit . AT.condensedExcerptToText 6 $
    AT.markup
      (fromString src)
      (Map.fromList annotations)

showSource1 :: Ord a => String -> (Range, a) -> Pretty (AnnotatedText a)
showSource1 src annotation = showSource src [annotation]

findTerm :: Seq (C.PathElement v loc) -> Maybe loc
findTerm = go
  where
    go (C.InSynthesize t :<| _) = Just $ ABT.annotation t
    go (C.InCheck t _ :<| _) = Just $ ABT.annotation t
    go (C.InSynthesizeApp _ t _ :<| _) = Just $ ABT.annotation t
    go (_ :<| t) = go t
    go Empty = Nothing

prettyTypecheckError ::
  (Var v, Ord loc, Show loc, Parser.Annotated loc) =>
  C.ErrorNote v loc ->
  Env ->
  String ->
  Path.Absolute ->
  Pretty ColorText
prettyTypecheckError note env src curPath =
  renderTypeError (typeErrorFromNote note) env src curPath

prettyTypeInfo ::
  (Var v, Ord loc, Show loc, Parser.Annotated loc) =>
  C.InfoNote v loc ->
  Env ->
  Pretty ColorText
prettyTypeInfo n e =
  maybe "" (`renderTypeInfo` e) (typeInfoFromNote n)

intLiteralSyntaxTip ::
  C.Term v loc -> C.Type v loc -> Pretty ColorText
intLiteralSyntaxTip term expectedType = case (term, expectedType) of
  (Term.Nat' n, Type.Ref' r)
    | r == Type.intRef ->
        "\nTip: Use the syntax "
          <> style Type2 ("+" <> show n)
          <> " to produce an "
          <> style Type2 "Int"
          <> "."
  _ -> ""

-- | Pretty prints resolution failure annotations, including a table of disambiguation
-- suggestions.
prettyResolutionFailures ::
  forall v a.
  (Annotated a, Var v, Ord a) =>
  -- | src
  String ->
  [Names.ResolutionFailure v a] ->
  Pretty ColorText
prettyResolutionFailures s allFailures =
  Pr.callout "❓" $
    Pr.linesNonEmpty
      [ Pr.wrap
          ("I couldn't resolve any of" <> style ErrorSite "these" <> "symbols:"),
        "",
        annotatedsAsErrorSite s (Names.getAnnotation <$> allFailures),
        "",
        ambiguitiesToTable allFailures
      ]
  where
    -- Collapses identical failures which may have multiple annotations into a single failure.
    -- uniqueFailures
    ambiguitiesToTable :: [Names.ResolutionFailure v a] -> Pretty ColorText
    ambiguitiesToTable failures =
      let pairs :: ([(v, Maybe (NESet String))])
          pairs = nubOrd . fmap toAmbiguityPair $ failures
          spacerRow = ("", "")
       in Pr.column2Header "Symbol" "Suggestions" $ spacerRow : (intercalateMap [spacerRow] prettyRow pairs)

    toAmbiguityPair :: Names.ResolutionFailure v annotation -> (v, Maybe (NESet String))
    toAmbiguityPair = \case
      (Names.TermResolutionFailure v _ (Names.Ambiguous names refs)) -> do
        let ppe = ppeFromNames names
         in (v, Just $ NES.map (showTermRef ppe) refs)
      (Names.TypeResolutionFailure v _ (Names.Ambiguous names refs)) -> do
        let ppe = ppeFromNames names
         in (v, Just $ NES.map (showTypeRef ppe) refs)
      (Names.TermResolutionFailure v _ Names.NotFound) -> (v, Nothing)
      (Names.TypeResolutionFailure v _ Names.NotFound) -> (v, Nothing)

    ppeFromNames :: Names.Names -> PPE.PrettyPrintEnv
    ppeFromNames names0 =
      PPE.fromNames PPE.todoHashLength (NamesWithHistory.NamesWithHistory {currentNames = names0, oldNames = mempty})

    prettyRow :: (v, Maybe (NESet String)) -> [(Pretty ColorText, Pretty ColorText)]
    prettyRow (v, mSet) = case mSet of
      Nothing -> [(prettyVar v, Pr.hiBlack "No matches")]
      Just suggestions -> zip ([prettyVar v] ++ repeat "") (Pr.string <$> toList suggestions)

useExamples :: Pretty ColorText
useExamples =
  Pr.lines
    [ "Here's a few examples of valid `use` statements:",
      "",
      Pr.indentN 2 . Pr.column2 $
        [ (Pr.blue "use math sqrt", Pr.wrap "Introduces `sqrt` as a local alias for `math.sqrt`"),
          (Pr.blue "use List :+", Pr.wrap "Introduces `:+` as a local alias for `List.:+`."),
          (Pr.blue "use .foo bar.baz", Pr.wrap "Introduces `bar.baz` as a local alias for the absolute name `.foo.bar.baz`")
        ]
    ]

prettyPath' :: Path.Path' -> Pretty ColorText
prettyPath' p' = Pr.blue (Pr.shown p')
