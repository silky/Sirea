{-# LANGUAGE EmptyDataDecls, FlexibleInstances #-}

-- | Declarative resource linking mechanism for Haskell.
--
-- RDP has a conservative notion of resources: services, resources,
-- shared state, etc. are external to behaviors; nothing is created,
-- nothing is destroyed. Developers will use discovery idioms, paths
-- and names. A useful idiom: abstract infinite spaces of resources,
-- and lazily initialize resources as they are discovered or used.
-- It is easy to partition infinite space into more infinite spaces.
-- Every RDP application can thus have its own, infinite corner of 
-- the universe. This is compatible with the perspective that it is 
-- RDP "all the way down" - an RDP application is a dynamic behavior
-- that manipulates resources in a local partition, provided by the
-- lower layer RDP behavior.
--
-- Sirea also uses this conservative notion of resources to achieve
-- a more declarative programming experience. This is expressed in
-- PCX, and is *type driven* - developers may find any resource of
-- class Resource.
--
-- The idea with PCX is to present resources as though they already
-- exist, as though PCX is an infinite namespace, and resources are
-- accessible if only we can name them. The naming in PCX is based
-- on Data.Typeable, though developers are free to extend this by
-- naming resources that represent spaces of resources with another
-- naming convention.
--
-- PCX is most useful for volatile resources, which will not survive
-- destruction of the Haskell process. Persistent resources benefit
-- by use of volatile proxies, e.g. to maintain connections, process
-- updates, cache values. PCX is used in Sirea core for threads and 
-- hooking up communication between them. It will be heavily used by 
-- FFI adapters, e.g. to represent control over a GLUT window.
--
-- NOTE: Threading PCX through an application would grow irritating.
-- However, a simple behavior transformer can make it a lot nicer.
-- Another module in Sirea will provide the BCX type to carry an
-- initial PCX to every element in a behavior that might want it.
--
-- NOTE: PCX is very simple and does not handle larger concerns such
-- as configurations, policies, and dependency injection. Don't try
-- to force it; configuration via mutable variables is just awkward.
-- I'll tackle those concerns at a higher layer (along with plugins,
-- live programming and configuration).
-- 
module Sirea.PCX
    ( PCX    -- abstract
    , newPCX -- a new toplevel
    , findInPCX -- the lookup function
    , Resource(..)
    ) where

import Data.Typeable
import Data.Dynamic
import Data.IORef
import Control.Monad.Fix (mfix)
import System.IO.Unsafe (unsafePerformIO, unsafeInterleaveIO)

-- | PCX p - Partition Resource Context. Abstract.
--
-- A partition context is an infinite, uniform space of resources.
-- It holds one resource of each type. Conceptually, it is already
-- holding those resources, and we just need to look for them. So
-- access to any particular resource is idempotent and offers a
-- pretense of purity.
--
-- Multiple instances of one type are easily achieved by modeling
-- another resource space as a resource. E.g. if you want a space
-- with integers mapped to state, you can do that - just write the
-- type and add a Resource instance for it. Child PCX contexts are
-- also accessible as resources.
--
-- NOTE: `PCX w` has connotations that `w` is the full world, i.e.
-- the root partition created by `newPCX`. It is also used in type
-- matching to provide a little extra protection against accidental
-- connections between SireaApp applications. `PCX p` refers to a
-- child PCX for a specific thread or partition. Partitions do not
-- directly share resources, but behaviors orchestrate communication
-- between partitions to allow indirect sharing.
--
-- Assume finding resources in PCX is moderately expensive. Rather
-- than looking for the resources you need each time you need them,
-- take them all up front.
--
data PCX p = PCX 
    { pcx_ident :: [TypeRep]
    , pcx_store :: IORef [Dynamic]
    }

instance Typeable1 PCX where
    typeOf1 _ = mkTyConApp tycPCX []
        where tycPCX = mkTyCon3 "Sirea" "PCX" "PCX"

-- | Resource - found inside a PCX. 
--
-- Resources are constructed in IO, but developers should protect an
-- illusion that resources existed prior the locator operation, i.e.
-- we are locating resources, not creating them. This requires:
--
--   * no observable side-effects in the locator
--   * no observable effects for mere existence of resource
--   * not sensitive to thread in which construction occurs
--
-- That is, we shouldn't see anything unless we agitate resources by
-- further IO operations.
class (Typeable r) => Resource r where
    locateResource :: PCX p -> IO r

instance (Typeable p) => Resource (PCX p) where
    locateResource pcx =
        mfix $ \ pcx' ->
        newIORef [] >>= \ store' ->
        let typ  = (head . typeRepArgs . typeOf) pcx' in
        let ident' = typ:(pcx_ident pcx) in
        return (PCX { pcx_ident = ident', pcx_store = store' })

-- Some utility instances.
instance Resource [TypeRep] where
    locateResource = return . pcx_ident
instance (Typeable a) => Resource (IORef (Maybe a)) where
    locateResource _ = newIORef Nothing
instance (Typeable a) => Resource (IORef [a]) where
    locateResource _ = newIORef []
instance (Resource x, Resource y) => Resource (x,y) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx)
instance (Resource x, Resource y, Resource z) => Resource (x,y,z) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx, findInPCX pcx)
instance (Resource w, Resource x, Resource y, Resource z) 
    => Resource (w,x,y,z) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx
                                ,findInPCX pcx, findInPCX pcx)
instance (Resource v, Resource w, Resource x, Resource y, Resource z) 
    => Resource (v,w,x,y,z) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx, findInPCX pcx
                                ,findInPCX pcx, findInPCX pcx)
instance (Resource u, Resource v, Resource w, Resource x
         ,Resource y, Resource z) => Resource (u,v,w,x,y,z) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx, findInPCX pcx
                                ,findInPCX pcx, findInPCX pcx, findInPCX pcx)
instance (Resource t, Resource u, Resource v, Resource w, Resource x
         ,Resource y, Resource z) => Resource (t,u,v,w,x,y,z) where
    locateResource pcx = return (findInPCX pcx, findInPCX pcx, findInPCX pcx
                , findInPCX pcx, findInPCX pcx, findInPCX pcx, findInPCX pcx)
   

-- | Find a resource in the partition context based on its type.
--
-- This provides a pure interface to represent that the resource
-- already exists (according to the abstraction) and we're just
-- searching for it. Resources are initialized lazily. Since 
-- lookups are idempotent, there are no issues of unsafe IO being
-- duplicated.
--
findInPCX :: (Resource r) => PCX p -> r
findInPCX = unsafePerformIO . findInPCX_IO

findInPCX_IO :: (Resource r) => PCX p -> IO r 
findInPCX_IO pcx =  
    unsafeInterleaveIO (locateResource pcx) >>= \ newR ->
    atomicModifyIORef (pcx_store pcx) (loadOrAdd newR)

loadOrAdd :: (Typeable r) => r -> [Dynamic] -> ([Dynamic],r)
loadOrAdd newR dynL =
    case fromDynList dynL of
        Just oldR -> (dynL, oldR)
        Nothing ->
            let dynR = toDyn newR in
            dynTypeRep dynR `seq` -- for consistency
            (dynR:dynL, newR)

fromDynList :: (Typeable r) => [Dynamic] -> Maybe r
fromDynList [] = Nothing
fromDynList (x:xs) = maybe (fromDynList xs) Just (fromDynamic x)

-- | newPCX - a `new` PCX space, unique and fresh.
-- You can find any number of child PCX spaces.
newPCX :: IO (PCX w)
newPCX = 
    newIORef [] >>= \ rf ->
    return $ PCX { pcx_ident = [], pcx_store = rf  }


