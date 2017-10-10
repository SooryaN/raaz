{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Interface for cryptographically secure random byte generators.
module Raaz.Random
       ( -- * Cryptographically secure randomness.
         -- $randomness$
         RT, RandM
       , randomByteString
       , random, randomiseCell
       -- ** Types that can be generated randomly
       , RandomStorable(..), unsafeFillRandomElements
         -- * Low level access to randomness.
       , fillRandomBytes
       , reseed
       -- * Internals
       -- $internals$
       ) where

import Control.Applicative
import Control.Monad
import Control.Monad.IO.Class
import Data.ByteString             ( ByteString             )
import Data.Int
import Data.Proxy                  ( Proxy(..)              )
import Data.Vector.Unboxed  hiding ( replicateM, create     )
import Data.Word

import Foreign.Ptr      ( Ptr     , castPtr)
import Foreign.Storable ( Storable, peek   )
import Prelude

import Raaz.Core
import Raaz.Core.Proxy
import Raaz.Cipher.ChaCha20.Internal(KEY, IV)
import Raaz.Random.ChaCha20PRG


-- $randomness$
--
-- The raaz library gives a relatively high level interface to
-- cryptographically secure randomness. The combinator `random`
-- generates pure value of certain types where as a sequence of random
-- bytes can be generated using the combinator
-- `randomByteString`. Both these combinators returns actions in the
-- `RandM`, the monad that captures actions that generate/use
-- cryptographically secure random bytes.
--
-- = Running a random action
--
-- There are two ways to run an `RandM` action, either `securely` or
-- `insecurely`. The only difference in these two is how they store
-- their seed in memory. The combinator `securely` ensures that the
-- seed of the CS-PRG is in a locked memory which is wiped clean after
-- the action is done. It is only needed in certain special cases
-- where the generated bytes needs to be kept secret, like for example
-- when generating long term keys. Even in those special cases, we
-- need to take extra precautions to ensure that no data is leaked
-- (details follow). For almost all other cases, we just need to use
-- `insecurely` as demonstrated below.
--
-- > -- Generate a pair of random Word8's
-- > import Raaz
-- > import Data.Word
-- >
-- > main :: IO ()
-- > main = insecurely rPair >>= print
-- >    where rPair :: RandM (Word8, Word8)
-- >          rPair = (,) <$> random <$> random
-- >
--
--
-- > -- A version of hello world that has gone nuts. Printed in base16
-- > -- to save some terminal grief.
-- >
-- > main = insecurely who >>= \ w -> putStrLn $ "hello " ++ showBase16 w
-- >   where who :: RandM ByteString
-- >         who = randomByteString 10
-- >
--
-- = Generating sensitive data
--
-- The pseudo-random generator exposed here is cryptographically
-- strong enough to be used in generating long term private key for a
-- PKI system. However, special care is to be taken when generating
-- such data as we do not want the data to be swapped out of the
-- memory. The `securely` combinator is precisely for this
-- scenario. However, it is not enough to just wrap a `RandM` action
-- in `securely` to avoid leaking sensitive data. The use of
-- `securely` instead of `insecurely` in the following code gives us
-- /no additional security/.
--
-- > -- Could as well use insecurely
-- > genWord64 :: IO Word64
-- > genWord64 = securely random
-- >
-- > -- Could as well use insecurely
-- > genRandomPassword :: IO ByteString
-- > genRandomPassword = securely $ randomByteString 42
--
-- Running a random action like `randomByteString`, using the
-- combinator `securely` only guarantees the seed is kept in locked
-- memory whereas the generated pure value resides in the unlocked
-- Haskell heap.  It is not feasible to ensure that the value is
-- stored in locked memory as the garbage collector often moves values
-- around. In general, it is not good to generate sensitive values as
-- a pure Haskell values. The solution we now describe gets into the
-- guts of the memory system of raaz. We recommend users who are not
-- developers of raaz or crypto-protocols on top of the raaz library,
-- to look for more high level solutions that hopefully raaz will
-- export.
--
-- The monad `RandM` is a specialisation of the more general random
-- monad @`RT` mem@ which captures a random actions that use an
-- additional memory element of type @mem@ (See the `Raaz.Core.Memory`
-- module for a description of the memory subsystem of raaz). The main
-- idea is to generate the random data directly into the additional
-- memory used by the action. A typical situation is to generate a
-- random element into a memory cell. This can be achieved by using
-- `randomiseCell` which, together with appropriate uses of
-- `onSubMemory`, should take care of most use cases of generating
-- sensitive data. Here is an example where we generate a key and iv
-- at randomly and perform an action with it.
--
-- > type SensitiveInfo = (MemoryCell Key, Memory IV)
-- >
-- > main :: IO ()
-- > main = securely $ do
-- >
-- >     -- Initialisation
-- >     onSubMemory fst randomiseCell -- randomise key
-- >     onSubMemory snd randomiseCell -- randomise iv
-- >
-- >     doSomethingWithKeyIV
--
-- More complicated interactions might require direct use of low level
-- buffer filling operations `fillRandomBytes` and
-- `fillRandomElements`. We recommend that this be avoided as much as
-- possible as they are prone to all the problems with pointer
-- functions.
--
--

-- $internals$
--
-- __Note:__ Only for developers and reviewers.
--
-- Generating unpredictable stream of bytes is one task that has burnt
-- the fingers of a lot of programmers. Unfortunately, getting it
-- correct is something of a black art. We give the internal details
-- of the cryptographic pseudo-random generator used in raaz. Note
-- that none of the details here are accessible or tuneable by the
-- user. This is a deliberate design choice to insulate the user from
-- things that are pretty easy to mess up.
--
-- The pseudo-random generator in Raaz uses the chacha20 stream
-- cipher. We more or less follow the /fast key erasure technique/
-- (<https://blog.cr.yp.to/20170723-random.html>) which is used in the
-- arc4random implementation in OpenBSD.  The two main steps in the
-- generation of the required random bytes are the following:
--
-- [Seeding:] Setting the internal state of of the chacha20 cipher,
-- i.e. its key, iv, and counter.
--
-- [Sampling:] Pre-computing a few blocks of the chacha20 key stream
-- in an auxiliary buffer which in turn is used to satisfy the
-- requests for random bytes.
--
-- The internal chacha20 state and auxilary buffer used to cache
-- generated random bytes is part of the memory used in the `RT` monad
-- and hence using `securely` will ensure that they are locked.
--
-- == Seeding.
--
-- We use the /system entropy source/ to seed the (key, iv) of the
-- chacha20 cipher.  Reading the system entropy source is a costly
-- affair as it often involves a system call. Therefore, seeding is
-- done at the beginning of the operation and once every 1G blocks
-- (64GB) of data generated. No direct access to the system entropy is
-- provided to the user except through the `reseed` combinator which
-- itself is not really recommended. This is a deliberate design
-- choice to avoid potential confusion and the resulting error for the
-- user.
--
-- User level libraries have very little access to actual entropy
-- sources and it is very difficult to ascertain the quality of the
-- ones that we do have. Therefore, we believe it is better to rely on
-- the operating system for the entropy needed for seeding. As a
-- result, security of PRG is crucially dependent on the quality of
-- system entropy source. If the seed is predictable then everything
-- till the next seeding (an infrequent event as explained above) is
-- deterministic and hence compromised. Be warned that the entropy in
-- many systems are quite low at certain epochs, like at the time of
-- startup. This can cause the PRG to be compromised. We try to
-- mitigate this by using the best know source for each supported
-- operating system. Given below is the list of our choice of entropy
-- source.
--
-- [OpenBSD/NetBSD:] The arc4random call.
--
-- [Linux:] Defaults to @\/dev\/urandom@ but has experimental support
-- for `getrandom` (needs testing). The `getrandom` call is better but
-- many current systems do not have support for this (needs kernel >
-- 3.17 and libc > 2.25).
--
-- [Other Posix:] Uses @\/dev\/urandom@
--
-- [Windows:] Support using CryptGenRandom from Wincrypt.h.
--
-- == Sampling.
--
-- Instead of running the chacha20 cipher for every request, we
-- generate 16 blocks of ChaCha20 key stream in an auxiliary buffer
-- and satisfy requests for random bytes from this buffer. To ensure
-- that the compromise of the PRG state does not compromise the random
-- data already generated and given out, we do the following.
--
-- 1. At each sampling, we re-initialise the (key,iv) pair using the
--    key size + iv size bytes from the auxiliary buffer. This ensures
--    that there is no way to know which key,iv pairs was used to
--    generate the current contents in the auxiliary buffer.
--
-- 2. Every use of data from the auxiliary buffer, whether it is to
--    satisfy a request for random bytes or to reinitialise the
--    (key,iv) pair in step 1 is wiped out immediately.
--
-- Assuming the security of the chacha20 stream cipher we have the
-- following security guarantee.
--
-- [Security Guarantee:] At any point of time, a compromise of the
-- cipher state (i.e. key iv pair) and/or the auxiliary buffer does
-- not reveal the random data that is given out previously.
--

-- | A batch of actions on the memory element @mem@ that uses some
-- randomness.
newtype RT mem a = RT { unRT :: MT (RandomState, mem) a }
                 deriving (Functor, Applicative, Monad, MonadIO)

-- | Run a randomness thread. In particular, this combinator takes
-- care of seeding the internal prg at the start.
seedAndRunRT :: RT m a
      -> MT (RandomState, m) a
seedAndRunRT action = onSubMemory fst reseedMT >> unRT action

-- | The monad for generating cryptographically secure random data.
type RandM = RT VoidMemory

instance MemoryThread RT where
  insecurely        = insecurely . seedAndRunRT
  securely          = securely   . seedAndRunRT
  liftMT            = RT . onSubMemory snd
  onSubMemory proj  = RT . onSubMemory projP . unRT
    where projP (rstate, mem) = (rstate, proj mem)
          -- No (misguided) use of functor instance for (,) here.

-- | Reseed from the system entropy pool. There is never a need to
-- explicitly seed your generator. The insecurely and securely calls
-- makes sure that your generator is seed before
-- starting. Furthermore, the generator also reseeds after every few
-- GB of random bytes that it generates. Generating random data from
-- the system entropy is usually an order of magnitude slower than
-- using a fast stream cipher. Reseeding often can slow your program
-- considerably without any additional security advantage.
--
reseed :: RT mem ()
reseed = RT $ onSubMemory fst reseedMT

-- | Fill the given input pointer with random bytes.
fillRandomBytes :: LengthUnit l => l ->  Pointer -> RT mem ()
fillRandomBytes l = RT . onSubMemory fst . fillRandomBytesMT l


-- | Instances of `Storable` which can be randomly generated. It might
-- appear that all instances of the class `Storable` should be
-- be instances of this class, after all we know the size of the
-- element, why not write that many random bytes. In fact, this module
-- provides an `unsafeFillRandomElements` which does that. However, we
-- do not give a blanket definition for all storables because for
-- certain refinements of a given type, like for example, Word8's
-- modulo 10, `unsafeFillRandomElements` introduces unacceptable
-- skews.
class Storable a => RandomStorable a where
  -- | Fill the buffer with so many random elements of type a.
  fillRandomElements :: Memory mem
                     => Int       -- ^ number of elements to fill
                     -> Ptr a     -- ^ The buffer to fill
                     -> RT mem ()

-- TOTHINK:
-- -------
--
-- Do we want to give a default definition like
--
-- > fillRandomElements = unsafeFillRandomElements
--
-- This would will make the instance definitions easier for the
-- Storables types that is spread over its entire range. However, it
-- would lead to a lazy definition which will compromise the quality
-- of the randomness.



-- | This is a helper function that has been exported to simplify the
-- definition of a `RandomStorable` instance for `Storable`
-- types. However, there is a reason why we do not give a blanket
-- instance for all instances `Storable` and why this function is
-- unsafe? This function generates a random element of type @a@ by
-- generating @n@ random bytes where @n@ is the size of the elements
-- of @a@. For instances that range the entire @n@ byte space this is
-- fine. However, if the type is actually a refinement of such a type,
-- (consider a @`Word8`@ modulo @10@ for example) this function
-- generates an unacceptable skew in the distribution. Hence this
-- function is prefixed unsafe.
unsafeFillRandomElements :: (Memory mem, Storable a) => Int -> Ptr a -> RT mem ()
unsafeFillRandomElements n ptr = fillRandomBytes totalSz $ castPtr ptr
  where totalSz = fromIntegral n * sizeOf (getProxy ptr)
        getProxy :: Ptr a -> Proxy a
        getProxy = proxyUnwrap . pure


-- | Generate a random element from an instance of a RandomStorable
-- element.
random :: (RandomStorable a, Memory mem) => RT mem a
random = RT $ liftPointerAction alloc (getIt . castPtr)
  where getIt ptr    = unRT $ fillRandomElements 1 ptr >> liftIO (peek ptr)
        alloc        :: Storable a => (Pointer -> IO a) -> IO a
        alloc action = allocaAligned algn sz action
          where getProxy   :: (Pointer -> IO b) -> Proxy b
                getProxy  _  = Proxy
                thisProxy    = getProxy action
                algn         = alignment thisProxy
                sz           = sizeOf    thisProxy

-- | Randomise the contents of a memory cell. Equivalent to @`random`
-- >>= liftMT . initialise@ but ensures that no data is transferred to
-- unlocked memory.
randomiseCell :: RandomStorable a => RT (MemoryCell a) ()
randomiseCell = getCellPointer >>= fillRandomElements 1

-- | Generate a random byteString.

randomByteString :: LengthUnit l
                 => l
                 -> RT mem ByteString
randomByteString l = RT $ onSubMemory fst  $ liftPointerAction (create l) $ fillRandomBytesMT l

------------------------------- Some instances of Random ------------------------

instance RandomStorable Word8 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Word16 where

  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Word32 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Word64 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Word where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Int8 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Int16 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Int32 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Int64 where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable Int where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable KEY where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable IV where
  fillRandomElements = unsafeFillRandomElements

instance RandomStorable w => RandomStorable (LE w) where
  fillRandomElements n = fillRandomElements n . lePtrToPtr
    where lePtrToPtr :: Ptr (LE w) -> Ptr w
          lePtrToPtr = castPtr

instance RandomStorable w => RandomStorable (BE w) where
  fillRandomElements n = fillRandomElements n . bePtrToPtr
    where bePtrToPtr :: Ptr (BE w) -> Ptr w
          bePtrToPtr = castPtr

instance (Dimension d, Unbox w, RandomStorable w) => RandomStorable (Tuple d w) where
  fillRandomElements n ptr = fillRandomElements (n * sz ptr) $ tupPtrToPtr ptr
    where sz   :: Dimension d => Ptr (Tuple d w) -> Int
          sz   = dimension' . proxyUnwrap . pure
          tupPtrToPtr ::  Ptr (Tuple d w) -> Ptr w
          tupPtrToPtr = castPtr
