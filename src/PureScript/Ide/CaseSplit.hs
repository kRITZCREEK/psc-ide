{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PackageImports   #-}
{-# LANGUAGE RecordWildCards  #-}
{-# LANGUAGE TemplateHaskell  #-}


module PureScript.Ide.CaseSplit where

import           Control.Concurrent.STM
import           "monad-logger" Control.Monad.Logger
import           Control.Monad.Reader
-- import Control.Lens
import qualified Data.Map                    as M
import           Data.Monoid
import           Data.Text                   (Text)
import qualified Data.Text                   as T
import           Language.PureScript.Externs
import           Language.PureScript.Names
import           Language.PureScript.Types
import           Language.PureScript.Pretty
import           Language.PureScript.Environment
import           PureScript.Ide.Completion
import           PureScript.Ide.State
import           PureScript.Ide.Types hiding (Type)

type Constructor = (Text, [(Text, Text)])

getExternFiles :: (PscIde m, MonadIO m) =>
                  m (M.Map ModuleName ExternsFile)
getExternFiles = do
  stateVar <- envStateVar <$> ask
  liftIO $ externsFiles <$> readTVarIO stateVar

findConstructors :: (PscIde m, MonadLogger m) =>
                    Text -> m [ExternsDeclaration]
findConstructors q = do
  module' <- findModuleForDatatype q
  case module' of
    Nothing -> do
        $(logDebug) $ "Couldn't find module for query: " <> q
        pure []
    Just m -> do
      efs <- getExternFiles
      ef' <- M.lookup m <$> getExternFiles
      case ef' of
        Nothing -> do
          $(logDebug) $ "Couldn't find ExternFile for query: " <> q
          pure []
        Just ef -> do
          -- $(logDebug) $ (T.pack . show $ findConstructors' (ProperName (T.unpack q)) ef)
          pure $ findConstructors' (ProperName (T.unpack q)) ef

caseSplit :: (PscIde m, MonadLogger m) =>
             Text -> m [Constructor]
caseSplit q = do
  ctors <- findConstructors q
  pure $ map mkCtor ctors

mkCtor :: ExternsDeclaration -> Constructor
mkCtor EDDataConstructor{..} = (T.pack $ runProperName edDataCtorName, args)
  where
    args = map (\t -> ("?x", T.strip . T.pack . prettyPrintType $ t)) ts
    (ts, _) = splitType edDataCtorType
mkCtor _ = error "lulz"

findModuleForDatatype :: (PscIde m, MonadIO m, MonadLogger m) =>
                         Text -> m (Maybe ModuleName)
findModuleForDatatype q = do
  matches <- getExactMatches q [] <$> getAllModulesWithReexports
  pure $ case matches of
    [] -> Nothing
    ((Completion (mn, _, _)):_) -> Just $ moduleNameFromString (T.unpack mn)

findConstructors' :: ProperName -> ExternsFile -> [ExternsDeclaration]
findConstructors' pn ef = filter doesConstruct (efDeclarations ef)
  where doesConstruct EDDataConstructor{..} = pn == edDataCtorTypeCtor
        doesConstruct _ = False

splitType :: Type -> ([Type], Type)
splitType t = (arguments, returns)
  where
    returns = last splitted
    arguments = init splitted
    splitted = splitType' t
    splitType' (ForAll _ t' _) = splitType' t'
    splitType' (TypeApp (TypeApp t' lhs) rhs)
          | t' == tyFunction = lhs : splitType' rhs
    splitType' t' = [t']

makeCases ::
  Text -> -- ^ function name
  [Text] -> -- ^ arguments so far
  Int -> -- ^ The argument to split on
  [Constructor] -> -- ^ the cases to cover
  [Text]
makeCases fName args n ctors =
  map makeLine ctors
  where
    argsl = take n args
    argsr = drop (n+1) args
    makeLine ctor = fName <> " " <> T.unwords (argsl ++ [prettyCtor ctor] ++ argsr) <> " = ?" <> fName

prettyCtor :: Constructor -> Text
prettyCtor (ctorName, []) = ctorName
prettyCtor (ctorName, ctorArgs) = "("<> ctorName <> " " <> T.unwords (map prettyCtorArg ctorArgs) <>")"

prettyCtorArg :: (Text, Text) -> Text
prettyCtorArg (s, t) = "(" <> s <> " :: " <> t <> ")"

makePattern ::
  Text ->
  Int -> Int ->
  [Constructor] ->
  [Text]
makePattern t x y ctors = makePattern' (T.take x t) (T.drop y t) ctors
  where
    makePattern' lhs rhs = map (\ctor -> lhs <> prettyCtor ctor <> rhs)
