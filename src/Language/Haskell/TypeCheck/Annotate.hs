module Language.Haskell.TypeCheck.Annotate ( AnnEnv(..), runReader, annotate ) where

import           Language.Haskell.Exts.SrcLoc
import           Language.Haskell.Exts.Syntax hiding (Type(..))
import qualified Language.Haskell.Exts.Syntax as HS

import           Language.Haskell.Scope (Origin(..), GlobalName(..))
import qualified Language.Haskell.Scope as Scope
import           Language.Haskell.TypeCheck.Monad
import           Language.Haskell.TypeCheck.Types
import qualified Language.Haskell.TypeCheck.Types as TC

import           Data.Map                         (Map)
import qualified Data.Map                         as Map
import Control.Monad.Reader

data AnnEnv = AnnEnv
  { annTypes :: Map GlobalName Type
  , annProofs :: Map SrcSpanInfo Proof }

type AnnM a = Reader AnnEnv a
type Ann a = a Origin -> AnnM (a Typed)
type AnnT t a = t (a Origin) -> AnnM (t (a Typed))

annotate :: Ann Module
annotate m =
  case m of
    Module origin mhead pragma imports decls ->
      Module <$> toTyped origin
        <*> annMaybe annModuleHead mhead
        <*> mapM annPragma pragma
        <*> mapM annImportDecl imports
        <*> mapM annDecl decls
    _ -> error "tiModule"

annDummy :: Functor a => Ann a
annDummy = pure . fmap dummy
  where
    dummy (Origin nameInfo srcspan) =
      case nameInfo of
        Scope.Resolved gname -> Resolved gname srcspan
        Scope.None           -> None srcspan
        Scope.ScopeError err -> ScopeError err srcspan

binding :: Origin -> AnnM Typed
binding (Origin nameInfo srcspan) =
  case nameInfo of
    Scope.Resolved gname -> do
      Just ty <- lookupType gname
      let GlobalName defLoc _qname = gname
      Just proof <- lookupProof defLoc
      pure $ Binding gname ty proof srcspan
    Scope.None           -> error "binding: None"
    Scope.ScopeError err -> error "binding: ScopeError"

usage :: Origin -> AnnM Typed
usage (Origin nameInfo srcspan) =
  case nameInfo of
    Scope.Resolved gname -> do
      Just proof <- lookupProof srcspan
      pure $ Usage gname proof srcspan
    Scope.None           -> error "binding: None"
    Scope.ScopeError err -> error "binding: ScopeError"

toTyped :: Origin -> AnnM Typed
toTyped (Origin nameInfo srcspan) =
  case nameInfo of
    Scope.Resolved gname -> pure $ Resolved gname srcspan
    Scope.None           -> pure $ None srcspan
    Scope.ScopeError err -> pure $ ScopeError err srcspan

annMaybe :: Ann a -> AnnT Maybe a
annMaybe _ Nothing   = pure Nothing
annMaybe fn (Just a) = Just <$> fn a

annModuleHead :: Ann ModuleHead
annModuleHead mhead =
  case mhead of
    ModuleHead origin name mbWarn mbExports ->
      ModuleHead <$> toTyped origin
        <*> annModuleName name
        <*> annMaybe annWarningText mbWarn
        <*> annMaybe annExportSpecList mbExports

annModuleName :: Ann ModuleName
annModuleName name =
  case name of
    ModuleName origin string ->
      ModuleName <$> toTyped origin <*> pure string

annWarningText :: Ann WarningText
annWarningText = annDummy

annExportSpecList :: Ann ExportSpecList
annExportSpecList = annDummy

annPragma :: Ann ModulePragma
annPragma = annDummy

annImportDecl :: Ann ImportDecl
annImportDecl = annDummy

annDecl :: Ann Decl
annDecl decl =
  case decl of
    FunBind origin matches ->
      FunBind
        <$> toTyped origin
        <*> mapM annMatch matches
    _ -> annDummy decl

annMatch :: Ann Match
annMatch match =
  case match of
    Match origin name pats rhs mbBinds ->
      Match
        <$> toTyped origin
        <*> annName binding name
        <*> mapM annPat pats
        <*> annRhs rhs
        <*> annMaybe annDummy mbBinds

annPat :: Ann Pat
annPat pat =
  case pat of
    PVar origin name ->
      PVar <$> toTyped origin <*> annName binding name
    _ -> annDummy pat

annName :: (Origin -> AnnM Typed) -> Ann Name
annName handler name =
  case name of
    Ident origin ident ->
      Ident <$> handler origin <*> pure ident
    _ -> annDummy name

annRhs :: Ann Rhs
annRhs rhs =
  case rhs of
    UnGuardedRhs origin expr ->
      UnGuardedRhs <$> toTyped origin <*> annExp expr
    _ -> annDummy rhs

annExp :: Ann Exp
annExp expr =
  case expr of
    Var origin qname ->
      Var <$> toTyped origin <*> annQName qname
    App origin a b ->
      App <$> toTyped origin <*> annExp a <*> annExp b
    Case origin scrut alts ->
      Case <$> toTyped origin <*> annExp scrut <*> mapM annAlt alts
    Paren origin e ->
      Paren <$> toTyped origin <*> annExp e
    _ -> annDummy expr

annAlt :: Ann Alt
annAlt (Alt origin pat rhs mbBinds) =
  Alt <$> toTyped origin
    <*> annPat pat
    <*> annRhs rhs
    <*> annMaybe annBinds mbBinds

annQName :: Ann QName
annQName qname =
  case qname of
    Qual origin modName name ->
      Qual <$> toTyped origin
        <*> annModuleName modName
        <*> annName usage name
    UnQual origin name ->
      UnQual <$> toTyped origin <*> annName usage name
    _ -> annDummy qname

annBinds :: Ann Binds
annBinds binds =
  case binds of
    BDecls origin decls ->
      BDecls <$> toTyped origin <*> mapM annDecl decls
    _ -> annDummy binds

------------------------------------
-- Misc

lookupType :: GlobalName -> AnnM (Maybe Type)
lookupType gname = asks $ Map.lookup gname . annTypes

lookupProof :: SrcSpanInfo -> AnnM (Maybe Proof)
lookupProof srcspan = asks $ Map.lookup srcspan . annProofs