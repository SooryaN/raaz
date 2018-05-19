{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE FlexibleInstances          #-}

{-# LANGUAGE MultiParamTypeClasses      #-}
{-# CFILES raaz/hash/sha1/portable.c    #-}

{-|

This module exposes the `SHA1` hash constructor. You would hardly need
to import the module directly as you would want to treat the `SHA1`
type as an opaque type for type safety. This module is exported only
for special uses like writing a test case or defining a binary
instance etc.

-}

module Raaz.Hash.Sha1.Internal (SHA1(..)) where

import           Data.String
import           Data.Word
import           Foreign.Storable    ( Storable(..) )

import           Raaz.Core

import           Raaz.Hash.Internal

-- | The cryptographic hash SHA1.
newtype SHA1 = SHA1 (Tuple 5 (BE Word32))
             deriving (Storable, EndianStore, Equality, Eq)

instance Encodable SHA1

instance IsString SHA1 where
  fromString = fromBase16

instance Show SHA1 where
  show = showBase16

instance Initialisable (HashMemory SHA1) () where
  initialise _ = initialise $ SHA1 $ unsafeFromList [ 0x67452301
                                                    , 0xefcdab89
                                                    , 0x98badcfe
                                                    , 0x10325476
                                                    , 0xc3d2e1f0
                                                    ]


instance Primitive SHA1 where
  type BlockSize SHA1      = 64
  type Implementation SHA1 = SomeHashI SHA1
  type Key SHA1            = ()
  type Digest SHA1         = SHA1

instance Hash SHA1 where
  additionalPadBlocks _ = toEnum 1
