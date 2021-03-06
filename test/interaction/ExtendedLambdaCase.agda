module ExtendedLambdaCase where

data Bool : Set where
  true false : Bool

data Void : Set where

foo : Bool -> Bool -> Bool -> Bool
foo = λ { x → λ { y z → {!!} } }

data Bar : (Bool -> Bool) -> Set where
  baz : (t : Void) -> Bar λ { x → {!!} }

-- with hidden argument
data Bar' : (Bool -> Bool) -> Set where
  baz' : {t : Void} -> Bar' λ { x' → {!!} }
