{-# LANGUAGE GADTs, Rank2Types, MultiParamTypeClasses, DeriveDataTypeable #-}

-- | This module contains the functions to run a Sirea application.
-- The main function you'll need is 'runSireaApp'. The rest can be
-- ignored unless you need to control the main thread loop or have
-- other special needs.
--
module Sirea.Activate
    ( runSireaApp
    , SireaAppObject(..)
    , buildSireaApp, beginSireaApp
    , bUnsafeExit
    ) where

import Prelude hiding (catch)
import Data.IORef
import Data.Typeable
import Control.Applicative
import Control.Concurrent.MVar
import Control.Monad (unless, when, void, liftM)
import Control.Exception (catch, AsyncException)
import Control.Concurrent (myThreadId, forkIO, killThread, threadDelay
                          ,rtsSupportsBoundThreads)
import Sirea.Internal.LTypes
import Sirea.Internal.B0Compile (compileB0)
import Sirea.Internal.PTypes
import Sirea.Internal.BCross
import Sirea.Internal.Thread
import Sirea.Internal.PulseSensor (getPulseRunner)
import Sirea.Internal.Tuning (dtRestart, dtHeartbeat, dtGrace, dtFinalize)
import Sirea.Behavior
import Sirea.Partition
import Sirea.UnsafeIO
import Sirea.PCX
import Sirea.B
import Sirea.Time
import Sirea.Signal

import Debug.Trace (traceIO)

-- IDEA: Have runSireaApp wrap the main application with a dynamic
-- behavior (bexec, etc.). Then use this to model restart. Switch
-- the application. 

-- IDEA: Separate update of 'content' and 'activity' signals, like
-- I expect to do for networked systems. This could potentially make
-- it easier to hold onto older values.

-- | The typical use case for Sirea is to simply runSireaApp as the
-- main operation, with enough abstraction that the app itself is a
-- one-liner. The application behavior is activated for side-effects
-- and the response signal is ignored. 
--
--    main :: IO ()
--    main = runSireaApp $ foo >>> bar >>> baz
--
-- runSireaApp will activate the behavior and keep it active until 
-- interrupted by any AsyncException in the initial thread. Ctrl+C
-- will cause such a exception. After interruption, runSireaApp will
-- begin a graceful shutdown. (If you interrupt twice, the graceful
-- shutdown will abort.)
--
runSireaApp :: B (S P0 ()) y -> IO ()
runSireaApp app = buildSireaApp (app >>> btrivial) >>= beginSireaApp

-- | SireaAppObject manages life cycle of an initialized SireaApp:
-- 
--     Stepper - for user-controlled event loops
--     Stopper - to halt the application gracefully
--
-- These types are defined in the Partition and PCX modules. The P0
-- partition is thus similar to other partitions, excepting Stopper
-- is provided to halt the whole app. Stopper is not instantaneous;
-- continue to runStepper until Stopper callback event is executed
-- to support graceful shutdown.
--
-- Note: If you want to integrate main thread resources, you should
-- abstract it through behaviors and AgentResource. Direct access to
-- PCX P0 is not available because it is too difficult to reuse code
-- specific to the P0 partition. 
--
data SireaAppObject = SireaAppObject 
    { sireaStepper :: Stepper
    , sireaStopper :: Stopper
    }

-- AppPeriodic data is used internally on the man clock step.
data AppPeriodic = AppPeriodic 
    { ap_cw     :: !(PCX W)
    , ap_tc0    :: !(TC)
    , ap_gs     :: !(GobStopper)
    , ap_pulse  :: !(IO ())
    , ap_sd     :: !(IORef StopData)
    , ap_link   :: !(LnkUp ())
    }


-- | If you need an external main event loop, use buildSireaApp to
-- integrate the Sirea events model with the external events model.
-- Otherwise, favor use of runSireaApp. (Relying on ad-hoc behavior
-- in the main thread results in systems that are less extensible 
-- and reusable than tasks represented in partition typeclasses and
-- controlled by external signals.)
--
buildSireaApp :: B (S P0 ()) S1 -> IO SireaAppObject
buildSireaApp app = 
    warnIfNotCompiledWithThreadedFlag >>
    newPCX [] >>= \ cw -> -- new global resource context
    getPCX0 cw >>= \ cp0 -> -- partition context P0
    findInPCX cp0 >>= \ tc0 ->
    writeIORef (tc_init tc0) True >>
    getPSched cp0 >>= \ pd ->
    -- compute behavior in the new context
    -- adds phase delay to model activation from abstract partition
    let b   = unwrapB (appWrap app) cw in
    let cc0 = CC { cc_getSched = return pd, cc_newRef = newRefIO } in
    let lc0 = LC { lc_dtCurr = 0, lc_dtGoal = 0, lc_cc = cc0 } in
    let lcaps = LnkSig (LCX lc0) in
    let (_, mkLn) = compileB0 b lcaps LnkDead in
    mkLn >>= \ lnk0 ->
    let lu = ln_lnkup lnk0 in
    buildSireaBLU cw lu

-- Sirea expects the -threaded flag.
warnIfNotCompiledWithThreadedFlag :: IO ()
warnIfNotCompiledWithThreadedFlag =
    unless rtsSupportsBoundThreads $
        traceIO ("Warning! Sirea app was not compiled with -threaded. "
                 ++ "May behave unpredictably, fail, or run slowly.")

-- To help make resets a bit more robust, I'm going to leverage the
-- dynamic behaviors model (which will basically compile the app per
-- active period). This should make it easier to GC connections and
-- recover a valid stability.
appWrap :: B (S P0 ()) S1 -> B (S P0 ()) S1
appWrap b =
    (wrapB . const) phaseUpdateB0 >>> 
    bdup >>> bfirst (bfmap (const b)) >>> 
    bexec 

getPCX0 :: PCX W -> IO (PCX P0)
getPCX0 = findInPCX
  
-- Build from a LnkUp, meaning there is something listening to the
-- signal. This doesn't actually initialize the signal, but does set
-- the app to kickstart on the first runStepper operation.
buildSireaBLU :: PCX W -> LnkUp () -> IO SireaAppObject
buildSireaBLU cw lu =
    newIORef emptyStopData >>= \ rfSD ->
    getPCX0 cw >>= \ cp0 ->
    findInPCX cp0 >>= \ tc0 ->
    addTCRecv tc0 (beginApp cw rfSD lu) >> -- add kickstart
    let stepper = tcToStepper tc0 in
    let stopper = makeStopper rfSD in
    return $ SireaAppObject { sireaStepper = stepper
                            , sireaStopper = stopper }
          
-- task to initialize application (performed on first runStepper)
-- a slight delay is introduced before everything really starts.
beginApp :: PCX W -> IORef StopData -> LnkUp () -> IO ()
beginApp cw rfSD lu = 
    findInPCX cw >>= \ gs ->
    getPCX0 cw >>= \ cp0 ->
    findInPCX cp0 >>= \ tc0 ->
    getPulseRunner cp0 >>= \ pulse ->    
    let ap = AppPeriodic 
                { ap_cw = cw
                , ap_tc0 = tc0
                , ap_gs = gs
                , ap_pulse = pulse
                , ap_sd = rfSD
                , ap_link = lu }
    in
    apTime ap >>= \ tNow ->
    let tS = StableT tNow in
    let tU = tNow `addTime` dtGrace in
    ln_update (ap_link ap) tS tU (s_always ()) >>
    apSched ap (maintainApp ap tS)
    
-- schedule will delay an event then perform it in another thread.
-- Sirea only does this with one thread at a time.
schedule :: IO () -> IO ()
schedule op = void $ forkIO (threadDelay hb >> op) where
    hb = fromInteger $ dtToNanos dtHeartbeat `div` 1000

apSched :: AppPeriodic -> IO () -> IO ()
apSched ap = schedule . addTCRecv (ap_tc0 ap)

apTime :: AppPeriodic -> IO T
apTime = getTCTime . ap_tc0

-- regular maintenance operation, simply increases stability of the
-- active signal on a regular basis; performed within main thread.
-- At any given time, one maintenance operation is either queued in
-- the main thread or delayed by a 'schedule' thread.
--
-- If there is a huge jump in stability (based on dtRestart tuning)
-- the app will adjust the signal to reflect the pause, basically to
-- kill the app for the period of activity. 
--
-- Note that restart takes precedence over halting. This is mostly
-- to ensure a period of inactivity is recorded if we halt right
-- on recovery.
maintainApp :: AppPeriodic -> StableT -> IO ()
maintainApp ap (StableT tS0) = 
    ap_pulse ap >> -- heartbeat
    readIORef (ap_sd ap) >>= \ sd ->
    if shouldStop sd then haltApp ap tS0 else
    apTime ap >>= \ tNow ->
    let tS = StableT tNow in
    apSched ap (maintainApp ap tS) >>
    if (tNow > (tS0 `addTime` dtRestart))
       then let tR = tNow `addTime` dtGrace in
            let tU = tS0 in
            let su = s_switch s_never tR (s_always ()) in
            let dt = tR `diffTime` tS0 in
            traceIO ("Sirea app restart; inactive for " ++ show dt ++ " seconds") >>
            ln_update (ap_link ap) tS tU su
       else ln_idle (ap_link ap) tS

-- termination signal requested since last heartbeat
haltApp :: AppPeriodic -> T -> IO ()
haltApp ap tHalt =
    apTime ap >>= \ tNow ->
    apSched ap (stoppingApp ap (tNow `addTime` dtGrace)) >>
    let tS = StableT (tNow `addTime` dtFinalize) in
    ln_update (ap_link ap) tS tHalt s_never

-- After we set the main signal to inactive, we must still wait for
-- real-time to catch up, and should run a final few heartbeats to
-- provide any pulse actions.
stoppingApp :: AppPeriodic -> T -> IO ()
stoppingApp ap tFinal = 
    ap_pulse ap >> -- heartbeat
    apTime ap >>= \ tNow ->
    if (tNow > tFinal) -- wait for real time to catch up
        then let onStop = ap_pulse ap >> finiStopData (ap_sd ap) in
             let gs = ap_gs ap in
             runGobStopper gs (addTCRecv (ap_tc0 ap) onStop) >>
             apSched ap (finalizingApp ap) 
        else apSched ap (stoppingApp ap tFinal)

-- at this point we've run the all-stop for all other threads,
-- so we're just biding time until threads report completion.
-- Continue to run any final heartbeats.
finalizingApp :: AppPeriodic -> IO ()
finalizingApp ap =
    ap_pulse ap >> -- heartbeat (potentially last)
    readIORef (ap_sd ap) >>= \ sd ->
    unless (isStopped sd) $
        apSched ap (finalizingApp ap)

-- | beginSireaApp activates a forever loop to process the SireaApp.
-- Stopped by asynchronous exception, such as killThread or ctrl+c 
-- user interrupt. (note: a double-kill will abort graceful kill)
beginSireaApp :: SireaAppObject -> IO ()
beginSireaApp so =
    let stepper = sireaStepper so in
    let stopper = sireaStopper so in
    newIORef True >>= \ rfContinue ->
    let onStop = writeIORef rfContinue False in
    addStopperEvent stopper onStop >>
    let loop = basicSireaAppLoop rfContinue stepper in
    let onSignal = runStopper stopper in
    loop `catch` \ e -> onAsyncException e (onSignal >> loop)

-- Haskell's exception mechanism requires a little help to derive
-- which exceptions are processed by which handlers.
onAsyncException :: AsyncException -> a -> a
onAsyncException = const id

-- the primary loop
basicSireaAppLoop :: IORef Bool -> Stepper -> IO ()
basicSireaAppLoop rfContinue stepper = 
    runStepper stepper >>
    readIORef rfContinue >>= \ bContinue ->
    when bContinue (wait >>= \ _ -> loop)
    where wait = newEmptyMVar >>= \ mvWait  ->
                 addStepperEvent stepper (putMVar mvWait ()) >>
                 takeMVar mvWait 
          loop = basicSireaAppLoop rfContinue stepper

-- | bUnsafeExit - used with runSireaApp or beginSireaApp; effect is
-- killThread on the main thread when first activated, initiating a
-- graceful shutdown.
--
-- The behavior of bUnsafeExit is not precise and not composable. If
-- developers wish to model precise shutdown behavior, they should
-- use dynamic behaviors and explicitly switch to shutdown behavior,
-- which could then perform this exit.
--
bUnsafeExit :: B (S P0 ()) (S P0 ())
bUnsafeExit = unsafeOnUpdateB $ \ cp0 -> 
    inExitR <$> findInPCX cp0 >>= \ rfKilled ->
    let kill = readIORef rfKilled >>= \ bBlooded ->
               unless bBlooded $ void $ 
                   writeIORef rfKilled True >>
                   -- note: fork to treat as async exception
                   -- respects mask; completes current step.
                   myThreadId >>= \ tidP0 ->
                   forkIO (killThread tidP0) 
    in
    return ((const . const) kill)

newtype ExitR = ExitR { inExitR :: IORef Bool } deriving (Typeable)
instance Resource P0 ExitR where
    locateResource _ _ = liftM ExitR $ newIORef False


