{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE Rank2Types            #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
-- |
-- Module      : Data.Array.Massiv.Delayed.Windowed
-- Copyright   : (c) Alexey Kuleshevich 2017
-- License     : BSD3
-- Maintainer  : Alexey Kuleshevich <lehins@yandex.ru>
-- Stability   : experimental
-- Portability : non-portable
--
module Data.Array.Massiv.Delayed.Windowed where

import           Control.Monad               (void, when)
import           Control.Monad.ST
import           Control.Monad.ST.Unsafe
import           Data.Array.Massiv.Common
import           Data.Array.Massiv.Delayed
import           Data.Array.Massiv.Scheduler

data WD

data instance Array WD ix e = WDArray { wdArray :: !(Array D ix e)
                                      , wdStencilSize :: Maybe ix
                                        -- ^ Setting this value during stencil
                                        -- application improves cache utilization
                                        -- while computing an array
                                      , wdWindowStartIndex :: !ix
                                      , wdWindowSize :: !ix
                                      , wdWindowUnsafeIndex :: ix -> e }

instance Index ix => Construct WD ix e where
  size = size . wdArray
  {-# INLINE size #-}

  getComp = dComp . wdArray
  {-# INLINE getComp #-}

  setComp c arr = arr { wdArray = (wdArray arr) { dComp = c } }
  {-# INLINE setComp #-}

  unsafeMakeArray c sz f = WDArray (unsafeMakeArray c sz f) Nothing zeroIndex zeroIndex f
  {-# INLINE unsafeMakeArray #-}


instance Functor (Array WD ix) where
  fmap f !arr =
    arr
    { wdArray = fmap f (wdArray arr)
    , wdWindowUnsafeIndex = f . wdWindowUnsafeIndex arr
    }
  {-# INLINE fmap #-}


-- | Supply a separate generating function for interior of an array. This is
-- very usful for stencil mapping, where interior function does not perform
-- boundary checks, thus significantly speeding up computation process.
makeArrayWindowed
  :: Source r ix e
  => Array r ix e -- ^ Source array that will have a window inserted into it
  -> ix -- ^ Start index for the window
  -> ix -- ^ Size of the window
  -> (ix -> e) -- ^ Inside window indexing function
  -> Array WD ix e
makeArrayWindowed !arr !wIx !wSz wUnsafeIndex
  | not (isSafeIndex sz wIx) =
    error $
    "Incorrect window starting index: " ++ show wIx ++ " for: " ++ show (size arr)
  | liftIndex2 (+) wIx wSz > sz =
    error $
    "Incorrect window size: " ++
    show wSz ++ " and/or placement: " ++ show wIx ++ " for: " ++ show (size arr)
  | otherwise =
    WDArray
    { wdArray = delay arr
    , wdStencilSize = Nothing
    , wdWindowStartIndex = wIx
    , wdWindowSize = wSz
    , wdWindowUnsafeIndex = wUnsafeIndex
    }
  where sz = size arr
{-# INLINE makeArrayWindowed #-}




instance {-# OVERLAPPING #-} Load WD Ix1 e where
  loadS (WDArray (DArray _ sz indexB) _ it wk indexW) _ unsafeWrite = do
    iterM_ 0 it 1 (<) $ \ !i -> unsafeWrite i (indexB i)
    iterM_ it wk 1 (<) $ \ !i -> unsafeWrite i (indexW i)
    iterM_ wk sz 1 (<) $ \ !i -> unsafeWrite i (indexB i)
  {-# INLINE loadS #-}
  loadP wIds (WDArray (DArray _ sz indexB) _ it wk indexW) _ unsafeWrite = do
      divideWork_ wIds wk $ \ !scheduler !chunkLength !totalLength !slackStart -> do
        scheduleWork scheduler $
          iterM_ 0 it 1 (<) $ \ !ix ->
            unsafeWrite (toLinearIndex sz ix) (indexB ix)
        scheduleWork scheduler $
          iterM_ wk sz 1 (<) $ \ !ix ->
            unsafeWrite (toLinearIndex sz ix) (indexB ix)
        loopM_ it (< (slackStart + it)) (+ chunkLength) $ \ !start ->
          scheduleWork scheduler $
          iterM_ start (start + chunkLength) 1 (<) $ \ !k ->
            unsafeWrite k $ indexW k
        scheduleWork scheduler $
          iterM_ (slackStart + it) (totalLength + it) 1 (<) $ \ !k ->
            unsafeWrite k (indexW k)
  {-# INLINE loadP #-}



instance {-# OVERLAPPING #-} Load WD Ix2 e where
  loadS arr _ unsafeWrite = do
    let (WDArray (DArray _ sz@(m :. n) indexB) mStencilSz (it :. jt) (wm :. wn) indexW) =
          arr
    let (ib :. jb) = (wm + it :. wn + jt)
        blockHeight = case mStencilSz of
                        Just (i :. _) -> i
                        _             -> 1
    iterM_ (0 :. 0) (it :. n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (ib :. 0) (m :. n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (it :. 0) (ib :. jt) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (it :. jb) (ib :. n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    unrollAndJam blockHeight (it :. ib) (jt :. jb) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexW ix)
  {-# INLINE loadS #-}
  loadP wIds arr _ unsafeWrite = do
    let (WDArray (DArray _ sz@(m :. n) indexB) mStencilSz (it :. jt) (wm :. wn) indexW) = arr
    withScheduler_ wIds $ \scheduler -> do
      let (ib :. jb) = (wm + it :. wn + jt)
          !blockHeight = case mStencilSz of
                           Just (i :. _) -> i
                           _             -> 1
          !(chunkHeight, slackHeight) = wm `quotRem` numWorkers scheduler
      let loadBlock !it' !ib' =
            unrollAndJam blockHeight (it' :. ib') (jt :. jb) $ \ !ix ->
              unsafeWrite (toLinearIndex sz ix) (indexW ix)
          {-# INLINE loadBlock #-}
      scheduleWork scheduler $
        iterM_ (0 :. 0) (it :. n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (ib :. 0) (m :. n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (it :. 0) (ib :. jt) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (it :. jb) (ib :. n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      loopM_ 0 (< numWorkers scheduler) (+ 1) $ \ !wid -> do
        let !it' = wid * chunkHeight + it
        scheduleWork scheduler $ loadBlock it' (it' + chunkHeight)
      when (slackHeight > 0) $ do
        let !itSlack = (numWorkers scheduler) * chunkHeight + it
        scheduleWork scheduler $
          loadBlock itSlack (itSlack + slackHeight)
  {-# INLINE loadP #-}

-- instance Load WD Ix3 e where
--   loadS = loadWindowedSRec
--   {-# INLINE loadS #-}
--   loadP = loadWindowedPRec
--   {-# INLINE loadP #-}

-- instance Load WD Ix4 e where
--   loadS = loadWindowedSRec
--   {-# INLINE loadS #-}
--   loadP = loadWindowedPRec
--   {-# INLINE loadP #-}

-- instance Load WD Ix5 e where
--   loadS = loadWindowedSRec
--   {-# INLINE loadS #-}
--   loadP = loadWindowedPRec
--   {-# INLINE loadP #-}

instance {-# OVERLAPPING #-} Load WD Ix3 e where
  loadS = loadWindowedSRec
  {-# INLINE loadS #-}
  loadP = loadWindowedPRec
  {-# INLINE loadP #-}


-- instance ( 4 <= n
--          , KnownNat n
--          , Index (Ix ((n - 1) - 1))
--          , Load WD (IxN (n - 1)) e
--          , IxN (n - 1) ~ Ix (n - 1)
--          ) =>
--          Load WD (IxN n) e where
--   loadS = loadWindowedSRec
--   {-# INLINE loadS #-}
--   loadP = loadWindowedPRec
--   {-# INLINE loadP #-}



instance {-# OVERLAPPABLE #-} (Index ix, Load WD (Lower ix) e) => Load WD ix e where
  loadS = loadWindowedSRec
  {-# INLINE loadS #-}
  loadP = loadWindowedPRec
  {-# INLINE loadP #-}


loadWindowedSRec :: (Index ix, Load WD (Lower ix) e) =>
  Array WD ix e -> (Int -> ST s e) -> (Int -> e -> ST s ()) -> ST s ()
loadWindowedSRec (WDArray darr mStencilSz tix wSz indexW) _unsafeRead unsafeWrite = do
  let DArray _ sz indexB = darr
      !szL = tailDim sz
      !bix = liftIndex2 (+) tix wSz
      !(t, tixL) = unconsDim tix
      !pageElements = totalElem szL
      unsafeWriteLower i k val = unsafeWrite (k + pageElements * i) val
      {-# INLINE unsafeWriteLower #-}
  iterM_ zeroIndex tix 1 (<) $ \ !ix ->
    unsafeWrite (toLinearIndex sz ix) (indexB ix)
  iterM_ bix sz 1 (<) $ \ !ix ->
    unsafeWrite (toLinearIndex sz ix) (indexB ix)
  loopM_ t (< headDim bix) (+ 1) $ \ !i ->
    let !lowerArr =
          (WDArray
             (DArray Seq szL (indexB . consDim i))
             (tailDim <$> mStencilSz) -- can safely drop the dim, only
                                      -- last 2 matter anyways
             tixL
             (tailDim wSz)
             (indexW . consDim i))
    in loadS lowerArr _unsafeRead (unsafeWriteLower i)
{-# INLINE loadWindowedSRec #-}


loadWindowedPRec :: (Index ix, Load WD (Lower ix) e) =>
  [Int] -> Array WD ix e -> (Int -> IO e) -> (Int -> e -> IO ()) -> IO ()
loadWindowedPRec wIds (WDArray darr mStencilSz tix wSz indexW) _unsafeRead unsafeWrite = do
  withScheduler_ wIds $ \ scheduler -> do
    let DArray _ sz indexB = darr
        !szL = tailDim sz
        !bix = liftIndex2 (+) tix wSz
        !(t, tixL) = unconsDim tix
        !pageElements = totalElem szL
        unsafeWriteLower i k = unsafeIOToST . unsafeWrite (k + pageElements * i)
        {-# INLINE unsafeWriteLower #-}
        -- unsafeWriteLowerST i k = unsafeIOToST . unsafeWriteLower i k
        -- {-# INLINE unsafeWriteLowerST #-}
    scheduleWork scheduler $
      iterM_ zeroIndex tix 1 (<) $ \ !ix ->
        unsafeWrite (toLinearIndex sz ix) (indexB ix)
    scheduleWork scheduler $
      iterM_ bix sz 1 (<) $ \ !ix ->
        unsafeWrite (toLinearIndex sz ix) (indexB ix)
    loopM_ t (< headDim bix) (+ 1) $ \ !i ->
      let !lowerArr =
            (WDArray
               (DArray Seq szL (indexB . consDim i))
               (tailDim <$> mStencilSz) -- can safely drop the dim, only
                                        -- last 2 matter anyways
               tixL
               (tailDim wSz)
               (indexW . consDim i))
      in scheduleWork scheduler $
         stToIO $
         loadS
           lowerArr
           (unsafeIOToST . _unsafeRead)
           (unsafeWriteLower i)
{-# INLINE loadWindowedPRec #-}



unrollAndJam :: Monad m =>
                Int -> Ix2 -> Ix2 -> (Ix2 -> m a) -> m ()
unrollAndJam !bH (it :. ib) (jt :. jb) f = do
  let !bH' = min (max 1 bH) 7
  let f2 (i :. j) = f (i :. j) >> f  (i+1 :. j)
  let f3 (i :. j) = f (i :. j) >> f2 (i+1 :. j)
  let f4 (i :. j) = f (i :. j) >> f3 (i+1 :. j)
  let f5 (i :. j) = f (i :. j) >> f4 (i+1 :. j)
  let f6 (i :. j) = f (i :. j) >> f5 (i+1 :. j)
  let f7 (i :. j) = f (i :. j) >> f6 (i+1 :. j)
  let f' = case bH' of
             1 -> f
             2 -> f2
             3 -> f3
             4 -> f4
             5 -> f5
             6 -> f6
             _ -> f7
  let !ibS = ib - ((ib - it) `mod` bH')
  loopM_ it (< ibS) (+ bH') $ \ !i ->
    loopM_ jt (< jb) (+ 1) $ \ !j ->
      f' (i :. j)
  loopM_ ibS (< ib) (+ 1) $ \ !i ->
    loopM_ jt (< jb) (+ 1) $ \ !j ->
      f (i :. j)
{-# INLINE unrollAndJam #-}


-- TODO: Implement Hilbert curve











instance {-# OVERLAPPING #-} Load WD Ix2T e where
  loadS arr _ unsafeWrite = do
    let (WDArray (DArray _ sz@(m, n) indexB) mStencilSz (it, jt) (wm, wn) indexW) =
          arr
    let (ib, jb) = (wm + it, wn + jt)
        blockHeight = case mStencilSz of
                        Just (i, _) -> i
                        _           -> 1
    iterM_ (0, 0) (it, n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (ib, 0) (m, n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (it, 0) (ib, jt) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    iterM_ (it, jb) (ib, n) 1 (<) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexB ix)
    unrollAndJamT blockHeight (it, ib) (jt, jb) $ \ !ix ->
      unsafeWrite (toLinearIndex sz ix) (indexW ix)
  {-# INLINE loadS #-}
  loadP wIds arr _ unsafeWrite = do
    let (WDArray (DArray _ sz@(m, n) indexB) mStencilSz (it, jt) (wm, wn) indexW) = arr
    withScheduler_ wIds $ \ scheduler -> do
      let (ib, jb) = (wm + it, wn + jt)
          blockHeight = case mStencilSz of
                          Just (i, _) -> i
                          _           -> 1
          !(chunkHeight, slackHeight) = wm `quotRem` numWorkers scheduler
      let loadBlock !it' !ib' =
            unrollAndJamT blockHeight (it', ib') (jt, jb) $ \ !ix ->
              unsafeWrite (toLinearIndex sz ix) (indexW ix)
          {-# INLINE loadBlock #-}
      scheduleWork scheduler $
        iterM_ (0, 0) (it, n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (ib, 0) (m, n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (it, 0) (ib, jt) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      scheduleWork scheduler $
        iterM_ (it, jb) (ib, n) 1 (<) $ \ !ix ->
          unsafeWrite (toLinearIndex sz ix) (indexB ix)
      loopM_ 0 (< numWorkers scheduler) (+ 1) $ \ !wid -> do
        let !it' = wid * chunkHeight + it
        scheduleWork scheduler $ loadBlock it' (it' + chunkHeight)
      when (slackHeight > 0) $ do
        let !itSlack = (numWorkers scheduler) * chunkHeight + it
        scheduleWork scheduler $ loadBlock itSlack (itSlack + slackHeight)
  {-# INLINE loadP #-}



unrollAndJamT :: Monad m =>
                Int -> Ix2T -> Ix2T -> (Ix2T -> m a) -> m ()
unrollAndJamT !bH (it, ib) (jt, jb) f = do
  let !bH' = min (max 1 bH) 7
  let f2 !(i, j) = f (i, j) >> f  (i+1, j)
  let f3 !(i, j) = f (i, j) >> f2 (i+1, j)
  let f4 !(i, j) = f (i, j) >> f3 (i+1, j)
  let f5 !(i, j) = f (i, j) >> f4 (i+1, j)
  let f6 !(i, j) = f (i, j) >> f5 (i+1, j)
  let f7 !(i, j) = f (i, j) >> f6 (i+1, j)
  let f' = case bH' of
             1 -> f
             2 -> f2
             3 -> f3
             4 -> f4
             5 -> f5
             6 -> f6
             _ -> f7
  let !ibS = ib - ((ib - it) `mod` bH')
  loopM_ it (< ibS) (+ bH') $ \ !i ->
    loopM_ jt (< jb) (+ 1) $ \ !j ->
      f' (i, j)
  loopM_ ibS (< ib) (+ 1) $ \ !i ->
    loopM_ jt (< jb) (+ 1) $ \ !j ->
      f (i, j)
{-# INLINE unrollAndJamT #-}
