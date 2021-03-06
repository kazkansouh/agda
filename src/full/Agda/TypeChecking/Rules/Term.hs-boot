
module Agda.TypeChecking.Rules.Term where

import qualified Agda.Syntax.Abstract as A
import Agda.Syntax.Internal
import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.TypeChecking.Monad.Base
import Control.Monad.Error (ErrorT)

checkExpr :: A.Expr -> Type -> TCM Term

data ExpandHidden = ExpandLast | DontExpandLast
data ExpandInstances = ExpandInstanceArguments | DontExpandInstanceArguments

checkArguments :: ExpandHidden -> ExpandInstances -> Range -> [NamedArg A.Expr] -> Type -> Type ->
                  ErrorT Type TCM (Args, Type)

