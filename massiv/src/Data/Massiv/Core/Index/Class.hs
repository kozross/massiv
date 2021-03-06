{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DefaultSignatures          #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
-- |
-- Module      : Data.Massiv.Core.Index.Class
-- Copyright   : (c) Alexey Kuleshevich 2018
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Data.Massiv.Core.Index.Class where

import           Control.DeepSeq           (NFData (..))
import           Data.Functor.Identity     (runIdentity)
import           Data.Massiv.Core.Iterator
import           GHC.TypeLits

-- | A way to select Array dimension at a value level.
newtype Dim = Dim Int deriving (Show, Eq, Ord, Num, Real, Integral, Enum)

-- | A way to select Array dimension at a type level.
data Dimension (n :: Nat) where
  Dim1 :: Dimension 1
  Dim2 :: Dimension 2
  Dim3 :: Dimension 3
  Dim4 :: Dimension 4
  Dim5 :: Dimension 5
  DimN :: (6 <= n, KnownNat n) => Dimension n

-- | A type level constraint that ensures index is indeed valid and that supplied dimension can be
-- safely used with it.
type IsIndexDimension ix n = (1 <= n, n <= Dimensions ix, Index ix, KnownNat n)

-- | Zero-dimension, i.e. a scalar. Can't really be used directly as there are no instances of
-- `Index` for it, and is included for completeness.
data Ix0 = Ix0 deriving (Eq, Ord, Show)

-- | 1-dimensional index. Synonym for `Int` and `Data.Massiv.Core.Index.Ix1`.
type Ix1T = Int

-- | 2-dimensional index as tuple of `Int`s.
type Ix2T = (Int, Int)

-- | 3-dimensional index as 3-tuple of `Int`s.
type Ix3T = (Int, Int, Int)

-- | 4-dimensional index as 4-tuple of `Int`s.
type Ix4T = (Int, Int, Int, Int)

-- | 5-dimensional index as 5-tuple of `Int`s.
type Ix5T = (Int, Int, Int, Int, Int)

-- | This type family will always point to a type for a dimension that is one lower than the type
-- argument.
type family Lower ix :: *

type instance Lower Ix1T = Ix0
type instance Lower Ix2T = Ix1T
type instance Lower Ix3T = Ix2T
type instance Lower Ix4T = Ix3T
type instance Lower Ix5T = Ix4T

-- | This is bread and butter of multi-dimensional array indexing. It is unlikely that any of the
-- functions in this class will be useful to a regular user, unless general algorithms are being
-- implemented that do span multiple dimensions.
class (Eq ix, Ord ix, Show ix, NFData ix) => Index ix where
  type Dimensions ix :: Nat

  -- | Dimensions of an array that has this index type, i.e. what is the dimensionality.
  dimensions :: ix -> Dim

  -- | Total number of elements in an array of this size.
  totalElem :: ix -> Int

  -- | Prepend a dimension to the index
  consDim :: Int -> Lower ix -> ix

  -- | Take a dimension from the index from the outside
  unconsDim :: ix -> (Int, Lower ix)

  -- | Apppend a dimension to the index
  snocDim :: Lower ix -> Int -> ix

  -- | Take a dimension from the index from the inside
  unsnocDim :: ix -> (Lower ix, Int)

  -- TODO: move out of the class
  -- | Remove a dimension from the index
  dropDim :: ix -> Dim -> Maybe (Lower ix)
  dropDim ix = fmap snd . pullOutDim ix
  {-# INLINE [1] dropDim #-}

  -- | Pull out value at specified dimension from the index, thus also lowering it dimensionality.
  pullOutDim :: ix -> Dim -> Maybe (Int, Lower ix)

  -- | Insert a dimension into the index
  insertDim :: Lower ix -> Dim -> Int -> Maybe ix

  -- | Extract the value index has at specified dimension.
  getDim :: ix -> Dim -> Maybe Int
  getDim = getIndex
  {-# INLINE [1] getDim #-}

  -- | Set the value for an index at specified dimension.
  setDim :: ix -> Dim -> Int -> Maybe ix
  setDim = setIndex
  {-# INLINE [1] setDim #-}

  -- TODO: depricate
  -- | Extract the value index has at specified dimension. To be deprecated.
  getIndex :: ix -> Dim -> Maybe Int
  getIndex = getDim
  {-# INLINE [1] getIndex #-}

  -- TODO: depricate
  -- | Set the value for an index at specified dimension. To be deprecated.
  setIndex :: ix -> Dim -> Int -> Maybe ix
  setIndex = setDim
  {-# INLINE [1] setIndex #-}

  -- | Lift an `Int` to any index by replicating the value as many times as there are dimensions.
  pureIndex :: Int -> ix

  -- | Zip together two indices with a function
  liftIndex2 :: (Int -> Int -> Int) -> ix -> ix -> ix

  -- | Map a function over an index
  liftIndex :: (Int -> Int) -> ix -> ix
  liftIndex f = liftIndex2 (\_ i -> f i) (pureIndex 0)
  {-# INLINE [1] liftIndex #-}

  foldlIndex :: (a -> Int -> a) -> a -> ix -> a
  default foldlIndex :: Index (Lower ix) => (a -> Int -> a) -> a -> ix -> a
  foldlIndex f !acc !ix = foldlIndex f (f acc i0) ixL
    where
      !(i0, ixL) = unconsDim ix
  {-# INLINE [1] foldlIndex #-}

  -- | Check whether index is within the size.
  isSafeIndex :: ix -- ^ Size
              -> ix -- ^ Index
              -> Bool
  default isSafeIndex :: Index (Lower ix) => ix -> ix -> Bool
  isSafeIndex !sz !ix = isSafeIndex n0 i0 && isSafeIndex szL ixL
    where
      !(n0, szL) = unconsDim sz
      !(i0, ixL) = unconsDim ix
  {-# INLINE [1] isSafeIndex #-}

  -- | Convert linear index from size and index
  toLinearIndex :: ix -- ^ Size
                -> ix -- ^ Index
                -> Int
  default toLinearIndex :: Index (Lower ix) => ix -> ix -> Int
  toLinearIndex !sz !ix = toLinearIndex szL ixL * n + i
    where !(szL, n) = unsnocDim sz
          !(ixL, i) = unsnocDim ix
  {-# INLINE [1] toLinearIndex #-}

  -- | Convert linear index from size and index with an accumulator. Currently is useless and will
  -- likley be removed in future versions.
  toLinearIndexAcc :: Int -> ix -> ix -> Int
  default toLinearIndexAcc :: Index (Lower ix) => Int -> ix -> ix -> Int
  toLinearIndexAcc !acc !sz !ix = toLinearIndexAcc (acc * n + i) szL ixL
    where !(n, szL) = unconsDim sz
          !(i, ixL) = unconsDim ix
  {-# INLINE [1] toLinearIndexAcc #-}

  -- | Compute an index from size and linear index
  fromLinearIndex :: ix -> Int -> ix
  default fromLinearIndex :: Index (Lower ix) => ix -> Int -> ix
  fromLinearIndex sz k = consDim q ixL
    where !(q, ixL) = fromLinearIndexAcc (snd (unconsDim sz)) k
  {-# INLINE [1] fromLinearIndex #-}

  -- | Compute an index from size and linear index using an accumulator, thus trying to optimize for
  -- tail recursion while getting the index computed.
  fromLinearIndexAcc :: ix -> Int -> (Int, ix)
  default fromLinearIndexAcc :: Index (Lower ix) => ix -> Int -> (Int, ix)
  fromLinearIndexAcc ix' !k = (q, consDim r ixL)
    where !(m, ix) = unconsDim ix'
          !(kL, ixL) = fromLinearIndexAcc ix k
          !(q, r) = quotRem kL m
  {-# INLINE [1] fromLinearIndexAcc #-}

  -- | A way to make sure index is withing the bounds for the supplied size. Takes two functions
  -- that will be invoked whenever index (2nd arg) is outsize the supplied size (1st arg)
  repairIndex :: ix -- ^ Size
              -> ix -- ^ Index
              -> (Int -> Int -> Int) -- ^ Repair when below zero
              -> (Int -> Int -> Int) -- ^ Repair when higher than size
              -> ix
  default repairIndex :: Index (Lower ix)
    => ix -> ix -> (Int -> Int -> Int) -> (Int -> Int -> Int) -> ix
  repairIndex !sz !ix rBelow rOver =
    consDim (repairIndex n i rBelow rOver) (repairIndex szL ixL rBelow rOver)
    where !(n, szL) = unconsDim sz
          !(i, ixL) = unconsDim ix
  {-# INLINE [1] repairIndex #-}

  -- | Iterator for the index. Same as `iterM`, but pure.
  iter :: ix -> ix -> ix -> (Int -> Int -> Bool) -> a -> (ix -> a -> a) -> a
  iter sIx eIx incIx cond acc f =
    runIdentity $ iterM sIx eIx incIx cond acc (\ix -> return . f ix)
  {-# INLINE iter #-}

  -- | This function is what makes it possible to iterate over an array of any dimension.
  iterM :: Monad m =>
           ix -- ^ Start index
        -> ix -- ^ End index
        -> ix -- ^ Increment
        -> (Int -> Int -> Bool) -- ^ Continue iterating while predicate is True (eg. until end of row)
        -> a -- ^ Initial value for an accumulator
        -> (ix -> a -> m a) -- ^ Accumulator function
        -> m a
  default iterM :: (Index (Lower ix), Monad m)
    => ix -> ix -> ix -> (Int -> Int -> Bool) -> a -> (ix -> a -> m a) -> m a
  iterM !sIx !eIx !incIx cond !acc f =
    loopM s (`cond` e) (+ inc) acc $ \ !i !acc0 ->
      iterM sIxL eIxL incIxL cond acc0 $ \ !ix ->
        f (consDim i ix)
    where
      !(s, sIxL) = unconsDim sIx
      !(e, eIxL) = unconsDim eIx
      !(inc, incIxL) = unconsDim incIx
  {-# INLINE iterM #-}

  -- TODO: Implement in terms of iterM, benchmark it and remove from `Index`
  -- | Same as `iterM`, but don't bother with accumulator and return value.
  iterM_ :: Monad m => ix -> ix -> ix -> (Int -> Int -> Bool) -> (ix -> m a) -> m ()
  default iterM_ :: (Index (Lower ix), Monad m)
    => ix -> ix -> ix -> (Int -> Int -> Bool) -> (ix -> m a) -> m ()
  iterM_ !sIx !eIx !incIx cond f =
    loopM_ s (`cond` e) (+ inc) $ \ !i ->
      iterM_ sIxL eIxL incIxL cond $ \ !ix ->
        f (consDim i ix)
    where
      !(s, sIxL) = unconsDim sIx
      !(e, eIxL) = unconsDim eIx
      !(inc, incIxL) = unconsDim incIx
  {-# INLINE iterM_ #-}


instance Index Ix1T where
  type Dimensions Ix1T = 1
  dimensions _ = 1
  {-# INLINE [1] dimensions #-}
  totalElem = id
  {-# INLINE [1] totalElem #-}
  isSafeIndex !k !i = 0 <= i && i < k
  {-# INLINE [1] isSafeIndex #-}
  toLinearIndex _ = id
  {-# INLINE [1] toLinearIndex #-}
  toLinearIndexAcc !acc m i  = acc * m + i
  {-# INLINE [1] toLinearIndexAcc #-}
  fromLinearIndex _ = id
  {-# INLINE [1] fromLinearIndex #-}
  fromLinearIndexAcc n k = k `quotRem` n
  {-# INLINE [1] fromLinearIndexAcc #-}
  repairIndex !k !i rBelow rOver
    | i < 0 = rBelow k i
    | i >= k = rOver k i
    | otherwise = i
  {-# INLINE [1] repairIndex #-}
  consDim i _ = i
  {-# INLINE [1] consDim #-}
  unconsDim i = (i, Ix0)
  {-# INLINE [1] unconsDim #-}
  snocDim _ i = i
  {-# INLINE [1] snocDim #-}
  unsnocDim i = (Ix0, i)
  {-# INLINE [1] unsnocDim #-}
  getIndex i 1 = Just i
  getIndex _ _ = Nothing
  {-# INLINE [1] getIndex #-}
  setIndex _ 1 i = Just i
  setIndex _ _ _ = Nothing
  {-# INLINE [1] setIndex #-}
  dropDim _ 1 = Just Ix0
  dropDim _ _ = Nothing
  {-# INLINE [1] dropDim #-}
  pullOutDim i 1 = Just (i, Ix0)
  pullOutDim _ _ = Nothing
  {-# INLINE [1] pullOutDim #-}
  insertDim Ix0 1 i = Just i
  insertDim _   _ _ = Nothing
  {-# INLINE [1] insertDim #-}
  pureIndex i = i
  {-# INLINE [1] pureIndex #-}
  liftIndex f = f
  {-# INLINE [1] liftIndex #-}
  liftIndex2 f = f
  {-# INLINE [1] liftIndex2 #-}
  foldlIndex f = f
  {-# INLINE [1] foldlIndex #-}
  iter k0 k1 inc cond = loop k0 (`cond` k1) (+inc)
  {-# INLINE iter #-}
  iterM k0 k1 inc cond = loopM k0 (`cond` k1) (+inc)
  {-# INLINE iterM #-}
  iterM_ k0 k1 inc cond = loopM_ k0 (`cond` k1) (+inc)
  {-# INLINE iterM_ #-}


instance Index Ix2T where
  type Dimensions Ix2T = 2
  dimensions _ = 2
  {-# INLINE [1] dimensions #-}
  totalElem (k2, k1) = k2 * k1
  {-# INLINE [1] totalElem #-}
  toLinearIndex (_, k1) (i2, i1) = k1 * i2 + i1
  {-# INLINE [1] toLinearIndex #-}
  fromLinearIndex (_, k1) !i = i `quotRem` k1
  {-# INLINE [1] fromLinearIndex #-}
  consDim = (,)
  {-# INLINE [1] consDim #-}
  unconsDim = id
  {-# INLINE [1] unconsDim #-}
  snocDim = (,)
  {-# INLINE [1] snocDim #-}
  unsnocDim = id
  {-# INLINE [1] unsnocDim #-}
  getIndex (i2,  _) 2 = Just i2
  getIndex ( _, i1) 1 = Just i1
  getIndex _      _ = Nothing
  {-# INLINE [1] getIndex #-}
  setIndex (_, i1) 2 i2 = Just (i2, i1)
  setIndex (i2, _) 1 i1 = Just (i2, i1)
  setIndex _      _ _ = Nothing
  {-# INLINE [1] setIndex #-}
  dropDim (_, i1) 2 = Just i1
  dropDim (i2, _) 1 = Just i2
  dropDim _      _ = Nothing
  {-# INLINE [1] dropDim #-}
  pullOutDim (i2, i1) 2 = Just (i2, i1)
  pullOutDim (i2, i1) 1 = Just (i1, i2)
  pullOutDim _        _ = Nothing
  {-# INLINE [1] pullOutDim #-}
  insertDim i1 2 i2 = Just (i2, i1)
  insertDim i2 1 i1 = Just (i2, i1)
  insertDim _  _  _ = Nothing
  {-# INLINE [1] insertDim #-}
  pureIndex i = (i, i)
  {-# INLINE [1] pureIndex #-}
  liftIndex2 f (i2, i1) (i2', i1') = (f i2 i2', f i1 i1')
  {-# INLINE [1] liftIndex2 #-}


instance Index Ix3T where
  type Dimensions Ix3T = 3
  dimensions _ = 3
  {-# INLINE [1] dimensions #-}
  totalElem  (k3, k2, k1) = k3 * k2 * k1
  {-# INLINE [1] totalElem #-}
  consDim i3 (i2, i1) = (i3, i2, i1)
  {-# INLINE [1] consDim #-}
  unconsDim (i3, i2, i1) = (i3, (i2, i1))
  {-# INLINE [1] unconsDim #-}
  snocDim (i3, i2) i1 = (i3, i2, i1)
  {-# INLINE [1] snocDim #-}
  unsnocDim (i3, i2, i1) = ((i3, i2), i1)
  {-# INLINE [1] unsnocDim #-}
  getIndex (i3,  _,  _) 3 = Just i3
  getIndex ( _, i2,  _) 2 = Just i2
  getIndex ( _,  _, i1) 1 = Just i1
  getIndex _            _ = Nothing
  {-# INLINE [1] getIndex #-}
  setIndex ( _, i2, i1) 3 i3 = Just (i3, i2, i1)
  setIndex (i3,  _, i1) 2 i2 = Just (i3, i2, i1)
  setIndex (i3, i2,  _) 1 i1 = Just (i3, i2, i1)
  setIndex _      _ _    = Nothing
  {-# INLINE [1] setIndex #-}
  dropDim ( _, i2, i1) 3 = Just (i2, i1)
  dropDim (i3,  _, i1) 2 = Just (i3, i1)
  dropDim (i3, i2,  _) 1 = Just (i3, i2)
  dropDim _      _    = Nothing
  {-# INLINE [1] dropDim #-}
  pullOutDim (i3, i2, i1) 3 = Just (i3, (i2, i1))
  pullOutDim (i3, i2, i1) 2 = Just (i2, (i3, i1))
  pullOutDim (i3, i2, i1) 1 = Just (i1, (i3, i2))
  pullOutDim _      _    = Nothing
  {-# INLINE [1] pullOutDim #-}
  insertDim (i2, i1) 3 i3 = Just (i3, i2, i1)
  insertDim (i3, i1) 2 i2 = Just (i3, i2, i1)
  insertDim (i3, i2) 1 i1 = Just (i3, i2, i1)
  insertDim _      _ _ = Nothing
  pureIndex i = (i, i, i)
  {-# INLINE [1] pureIndex #-}
  liftIndex2 f (i3, i2, i1) (i3', i2', i1') = (f i3 i3', f i2 i2', f i1 i1')
  {-# INLINE [1] liftIndex2 #-}


instance Index Ix4T where
  type Dimensions Ix4T = 4
  dimensions _ = 4
  {-# INLINE [1] dimensions #-}
  totalElem !(k4, k3, k2, k1) = k4 * k3 * k2 * k1
  {-# INLINE [1] totalElem #-}
  consDim i4 (i3, i2, i1) = (i4, i3, i2, i1)
  {-# INLINE [1] consDim #-}
  unconsDim (i4, i3, i2, i1) = (i4, (i3, i2, i1))
  {-# INLINE [1] unconsDim #-}
  snocDim (i4, i3, i2) i1 = (i4, i3, i2, i1)
  {-# INLINE [1] snocDim #-}
  unsnocDim (i4, i3, i2, i1) = ((i4, i3, i2), i1)
  {-# INLINE [1] unsnocDim #-}
  getIndex (i4,  _,  _,  _) 4 = Just i4
  getIndex ( _, i3,  _,  _) 3 = Just i3
  getIndex ( _,  _, i2,  _) 2 = Just i2
  getIndex ( _,  _,  _, i1) 1 = Just i1
  getIndex _                _ = Nothing
  {-# INLINE [1] getIndex #-}
  setIndex ( _, i3, i2, i1) 4 i4 = Just (i4, i3, i2, i1)
  setIndex (i4,  _, i2, i1) 3 i3 = Just (i4, i3, i2, i1)
  setIndex (i4, i3,  _, i1) 2 i2 = Just (i4, i3, i2, i1)
  setIndex (i4, i3, i2,  _) 1 i1 = Just (i4, i3, i2, i1)
  setIndex _                _  _ = Nothing
  {-# INLINE [1] setIndex #-}
  dropDim ( _, i3, i2, i1) 4 = Just (i3, i2, i1)
  dropDim (i4,  _, i2, i1) 3 = Just (i4, i2, i1)
  dropDim (i4, i3,  _, i1) 2 = Just (i4, i3, i1)
  dropDim (i4, i3, i2,  _) 1 = Just (i4, i3, i2)
  dropDim _                _ = Nothing
  {-# INLINE [1] dropDim #-}
  pullOutDim (i4, i3, i2, i1) 4 = Just (i4, (i3, i2, i1))
  pullOutDim (i4, i3, i2, i1) 3 = Just (i3, (i4, i2, i1))
  pullOutDim (i4, i3, i2, i1) 2 = Just (i2, (i4, i3, i1))
  pullOutDim (i4, i3, i2, i1) 1 = Just (i1, (i4, i3, i2))
  pullOutDim _                _ = Nothing
  {-# INLINE [1] pullOutDim #-}
  insertDim (i3, i2, i1) 4 i4 = Just (i4, i3, i2, i1)
  insertDim (i4, i2, i1) 3 i3 = Just (i4, i3, i2, i1)
  insertDim (i4, i3, i1) 2 i2 = Just (i4, i3, i2, i1)
  insertDim (i4, i3, i2) 1 i1 = Just (i4, i3, i2, i1)
  insertDim _            _  _ = Nothing
  {-# INLINE [1] insertDim #-}
  pureIndex i = (i, i, i, i)
  {-# INLINE [1] pureIndex #-}
  liftIndex2 f (i4, i3, i2, i1) (i4', i3', i2', i1') = (f i4 i4', f i3 i3', f i2 i2', f i1 i1')
  {-# INLINE [1] liftIndex2 #-}


instance Index Ix5T where
  type Dimensions Ix5T = 5
  dimensions _ = 5
  {-# INLINE [1] dimensions #-}
  totalElem !(n5, n4, n3, n2, n1) = n5 * n4 * n3 * n2 * n1
  {-# INLINE [1] totalElem #-}
  consDim i5 (i4, i3, i2, i1) = (i5, i4, i3, i2, i1)
  {-# INLINE [1] consDim #-}
  unconsDim (i5, i4, i3, i2, i1) = (i5, (i4, i3, i2, i1))
  {-# INLINE [1] unconsDim #-}
  snocDim (i5, i4, i3, i2) i1 = (i5, i4, i3, i2, i1)
  {-# INLINE [1] snocDim #-}
  unsnocDim (i5, i4, i3, i2, i1) = ((i5, i4, i3, i2), i1)
  {-# INLINE [1] unsnocDim #-}
  getIndex (i5,  _,  _,  _,  _) 5 = Just i5
  getIndex ( _, i4,  _,  _,  _) 4 = Just i4
  getIndex ( _,  _, i3,  _,  _) 3 = Just i3
  getIndex ( _,  _,  _, i2,  _) 2 = Just i2
  getIndex ( _,  _,  _,  _, i1) 1 = Just i1
  getIndex _                _     = Nothing
  {-# INLINE [1] getIndex #-}
  setIndex ( _, i4, i3, i2, i1) 5 i5 = Just (i5, i4, i3, i2, i1)
  setIndex (i5,  _, i3, i2, i1) 4 i4 = Just (i5, i4, i3, i2, i1)
  setIndex (i5, i4,  _, i2, i1) 3 i3 = Just (i5, i4, i3, i2, i1)
  setIndex (i5, i4, i3,  _, i1) 2 i2 = Just (i5, i4, i3, i2, i1)
  setIndex (i5, i4, i3, i2,  _) 1 i1 = Just (i5, i4, i3, i2, i1)
  setIndex _                    _  _ = Nothing
  {-# INLINE [1] setIndex #-}
  dropDim ( _, i4, i3, i2, i1) 5 = Just (i4, i3, i2, i1)
  dropDim (i5,  _, i3, i2, i1) 4 = Just (i5, i3, i2, i1)
  dropDim (i5, i4,  _, i2, i1) 3 = Just (i5, i4, i2, i1)
  dropDim (i5, i4, i3,  _, i1) 2 = Just (i5, i4, i3, i1)
  dropDim (i5, i4, i3, i2,  _) 1 = Just (i5, i4, i3, i2)
  dropDim _                    _ = Nothing
  {-# INLINE [1] dropDim #-}
  pullOutDim (i5, i4, i3, i2, i1) 5 = Just (i5, (i4, i3, i2, i1))
  pullOutDim (i5, i4, i3, i2, i1) 4 = Just (i4, (i5, i3, i2, i1))
  pullOutDim (i5, i4, i3, i2, i1) 3 = Just (i3, (i5, i4, i2, i1))
  pullOutDim (i5, i4, i3, i2, i1) 2 = Just (i2, (i5, i4, i3, i1))
  pullOutDim (i5, i4, i3, i2, i1) 1 = Just (i1, (i5, i4, i3, i2))
  pullOutDim _                    _ = Nothing
  {-# INLINE [1] pullOutDim #-}
  insertDim (i4, i3, i2, i1) 5 i5 = Just (i5, i4, i3, i2, i1)
  insertDim (i5, i3, i2, i1) 4 i4 = Just (i5, i4, i3, i2, i1)
  insertDim (i5, i4, i2, i1) 3 i3 = Just (i5, i4, i3, i2, i1)
  insertDim (i5, i4, i3, i1) 2 i2 = Just (i5, i4, i3, i2, i1)
  insertDim (i5, i4, i3, i2) 1 i1 = Just (i5, i4, i3, i2, i1)
  insertDim _            _  _     = Nothing
  {-# INLINE [1] insertDim #-}
  pureIndex i = (i, i, i, i, i)
  {-# INLINE [1] pureIndex #-}
  liftIndex2 f (i5, i4, i3, i2, i1) (i5', i4', i3', i2', i1') =
    (f i5 i5', f i4 i4', f i3 i3', f i2 i2', f i1 i1')
  {-# INLINE [1] liftIndex2 #-}

-- | Helper function for throwing out of bounds errors
errorIx :: (Show ix, Show ix') => String -> ix -> ix' -> a
errorIx fName sz ix =
  error $
  fName ++
  ": Index out of bounds: (" ++ show ix ++ ") for Array of size: (" ++ show sz ++ ")"
{-# NOINLINE errorIx #-}


-- | Helper function for throwing error when sizes do not match
errorSizeMismatch :: (Show ix, Show ix') => String -> ix -> ix' -> a
errorSizeMismatch fName sz sz' =
  error $ fName ++ ": Mismatch in size of arrays " ++ show sz ++ " vs " ++ show sz'
{-# NOINLINE errorSizeMismatch #-}
