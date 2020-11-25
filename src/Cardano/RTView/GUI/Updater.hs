{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

module Cardano.RTView.GUI.Updater
    ( updateGUI
    -- For special cases
    , justUpdateErrorsListAndTab
    ) where

import           Control.Concurrent.STM.TVar (TVar, modifyTVar', readTVarIO)
import           Control.Monad (void, forM, forM_, unless, when)
import           Control.Monad.STM (atomically)
import           Control.Monad.Extra (ifM, whenJust, whenJustM)
import qualified Data.List as L
import           Data.Maybe (fromJust, isJust)
import           Data.HashMap.Strict ((!), (!?))
import qualified Data.HashMap.Strict as HM
import           Data.Text (Text, pack, strip, unpack)
import qualified Data.Text as T
import           Data.Time.Calendar (diffDays)
import           Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime, getCurrentTime,
                                  diffUTCTime)
import           Data.Time.Format (defaultTimeLocale, formatTime)
import           Data.Word (Word64)
import           GHC.Clock (getMonotonicTimeNSec)
import qualified Graphics.UI.Threepenny as UI
import           Graphics.UI.Threepenny.Core (Element, UI, children, element, liftIO, set, style,
                                              text, (#), (#+))

import           Cardano.BM.Data.Severity (Severity (..))

import           Cardano.RTView.CLI (RTViewParams (..))
import           Cardano.RTView.GUI.Elements (ElementName (..), ElementValue (..),
                                              HTMLClass (..), HTMLId (..),
                                              NodeStateElements, NodesStateElements,
                                              PeerInfoElements (..), PeerInfoItem (..),
                                              (#.), hideIt, showInline, pageTitle, pageTitleNotify)
import           Cardano.RTView.GUI.Markup.Grid (allMetricsNames)
import qualified Cardano.RTView.GUI.JS.Charts as Chart
import           Cardano.RTView.NodeState.CSV (mkCSVWithErrorsForHref)
import           Cardano.RTView.NodeState.Types
import           Cardano.RTView.SupportedNodes (supportedNodesVersions, showSupportedNodesVersions)

-- | This function is calling by the timer. It updates the node' state elements
--   on the page automatically, because threepenny-gui is based on websockets.
updateGUI
  :: UI.Window
  -> TVar NodesState
  -> RTViewParams
  -> (NodesStateElements, NodesStateElements)
  -> UI ()
updateGUI window nsTVar params (nodesStateElems, gridNodesStateElems) =
  -- Only one GUI mode can be active now, so check it and update only corresponding elements.
  whenJustM (UI.getElementById window (show ViewModeButton)) $ \btn ->
    UI.get UI.value btn >>= \case
      "paneMode" -> updatePaneGUI window nsTVar params nodesStateElems
      _ ->          updateGridGUI window nsTVar params gridNodesStateElems

updatePaneGUI
  :: UI.Window
  -> TVar NodesState
  -> RTViewParams
  -> NodesStateElements
  -> UI ()
updatePaneGUI window tv params nodesStateElems = do
  nodesState <- liftIO $ readTVarIO tv

  resetPageTitleIfNeeded window tv

  forM_ nodesStateElems $ \(nName, els, peerInfoItems) -> do
    let NodeState {..}         = nodesState ! nName
        PeerMetrics {..}       = peersMetrics
        MempoolMetrics {..}    = mempoolMetrics
        ForgeMetrics {..}      = forgeMetrics
        RTSMetrics {..}        = rtsMetrics
        BlockchainMetrics {..} = blockchainMetrics
        KESMetrics {..}        = kesMetrics
        nm@NodeMetrics {..}    = nodeMetrics
        ErrorsMetrics {..}     = nodeErrors

    updateErrorsListAndTab window tv nName errors errorsChanged els
                           ElNodeErrors ElNodeErrorsTab ElNodeErrorsTabBadge ElDownloadErrorsAsCSV
    updatePeersList tv nName peersInfo peersInfoChanged peerInfoItems

    -- TODO: temporary solution, progress bars will be replaced by charts soon.
    updateProgressBar mempoolBytesPercent  els ElMempoolBytesProgress
    updateProgressBar mempoolTxsPercent    els ElMempoolTxsProgress
    updateProgressBar rtsMemoryUsedPercent els ElRTSMemoryProgress

    nodeIsIdle <- checkIfNodeIsIdlePane params metricsLastUpdate (els ! ElIdleNode) (els ! ElNodePane)
    unless nodeIsIdle $ do
      setNodeStartTime  tv nName nodeStartTime nodeStartTimeChanged els ElNodeStarttime
      setNodeUpTime nodeStartTime els ElNodeUptime

      setNodeVersion    tv nName (TextV    nodeVersion)          nodeVersionChanged        els ElNodeVersion
      setNodeProtocol   tv nName (TextV    nodeProtocol)         nodeProtocolChanged       els ElNodeProtocol
      setNodePlatform   tv nName (TextV    nodePlatform)         nodePlatformChanged       els ElNodePlatform
      setEpoch          tv nName (IntegerV epoch)                epochChanged              els ElEpoch
      setSlot           tv nName (IntegerV slot)                 slotChanged               els ElSlot
      setBlocksNumber   tv nName (IntegerV blocksNumber)         blocksNumberChanged       els ElBlocksNumber
      setChainDensity   tv nName (DoubleV  chainDensity)         chainDensityChanged       els ElChainDensity
      setForgedNum      tv nName (IntegerV blocksForgedNumber)   blocksForgedNumberChanged els ElBlocksForgedNumber
      setCannotForge    tv nName (IntegerV nodeCannotForge)      nodeCannotForgeChanged    els ElNodeCannotForge
      setNodeIsLeader   tv nName (IntegerV nodeIsLeaderNum)      nodeIsLeaderNumChanged    els ElNodeIsLeaderNumber
      setSlotsMissed    tv nName (IntegerV slotsMissedNumber)    slotsMissedNumberChanged  els ElSlotsMissedNumber
      setTxsProcessed   tv nName (IntegerV txsProcessed)         txsProcessedChanged       els ElTxsProcessed
      setMPoolTxsNum    tv nName (IntegerV mempoolTxsNumber)     mempoolTxsNumberChanged   els ElMempoolTxsNumber
      setMPoolTxsPerc   tv nName (DoubleV  mempoolTxsPercent)    mempoolTxsPercentChanged   els ElMempoolTxsPercent
      setMPoolBytes     tv nName (Word64V  mempoolBytes)         mempoolBytesChanged       els ElMempoolBytes
      setMPoolBytesPerc tv nName (DoubleV  mempoolBytesPercent)  mempoolBytesPercentChanged els ElMempoolBytesPercent
      setMPoolMaxTxs    tv nName (IntegerV mempoolMaxTxs)        mempoolMaxTxsChanged      els ElMempoolMaxTxs
      setMPoolMaxBytes  tv nName (IntegerV mempoolMaxBytes)      mempoolMaxBytesChanged    els ElMempoolMaxBytes
      setRtsMemAlloc    tv nName (DoubleV  rtsMemoryAllocated)   rtsMemoryAllocatedChanged els ElRTSMemoryAllocated
      setRtsMemUsed     tv nName (DoubleV  rtsMemoryUsed)        rtsMemoryUsedChanged      els ElRTSMemoryUsed
      setRtsMemUsedPerc tv nName (DoubleV  rtsMemoryUsedPercent) rtsMemoryUsedPercentChanged els ElRTSMemoryUsedPercent
      setRtsGcCpu       tv nName (DoubleV  rtsGcCpu)             rtsGcCpuChanged           els ElRTSGcCpu
      setRtsGcElapsed   tv nName (DoubleV  rtsGcElapsed)         rtsGcElapsedChanged       els ElRTSGcElapsed
      setRtsGcNum       tv nName (IntegerV rtsGcNum)             rtsGcNumChanged           els ElRTSGcNum
      setRtsGcMajorNum  tv nName (IntegerV rtsGcMajorNum)        rtsGcMajorNumChanged      els ElRTSGcMajorNum
      setStartKES       tv nName (IntegerV opCertStartKESPeriod)  opCertStartKESPeriodChanged  els ElOpCertStartKESPeriod
      setExpiryKES      tv nName (IntegerV opCertExpiryKESPeriod) opCertExpiryKESPeriodChanged els ElOpCertExpiryKESPeriod
      setCurrentKES     tv nName (IntegerV currentKESPeriod)      currentKESPeriodChanged      els ElCurrentKESPeriod
      setRemKES         tv nName (IntegerV remKESPeriods)       remKESPeriodsChanged       els ElRemainingKESPeriods
      setRemKESDays     tv nName (IntegerV remKESPeriodsInDays) remKESPeriodsInDaysChanged els ElRemainingKESPeriodsInDays
      setSystemStart    tv nName systemStartTime  systemStartTimeChanged els ElSystemStartTime
      setNodeCommit     tv nName nodeCommit nodeShortCommit nodeCommitChanged els ElNodeCommitHref

      updateCharts window nName resourcesMetrics nm

updateGridGUI
  :: UI.Window
  -> TVar NodesState
  -> RTViewParams
  -> NodesStateElements
  -> UI ()
updateGridGUI window tv params gridNodesStateElems = do
  nodesState <- liftIO $ readTVarIO tv
  forM_ gridNodesStateElems $ \(nName, els, _) -> do
    let NodeState {..}         = nodesState ! nName
        PeerMetrics {..}       = peersMetrics
        MempoolMetrics {..}    = mempoolMetrics
        ForgeMetrics {..}      = forgeMetrics
        rm                     = resourcesMetrics
        RTSMetrics {..}        = rtsMetrics
        BlockchainMetrics {..} = blockchainMetrics
        KESMetrics {..}        = kesMetrics
        nm@NodeMetrics {..}    = nodeMetrics

    nodeIsIdle <- checkIfNodeIsIdleGrid window params metricsLastUpdate (els ! ElIdleNode) nName
    unless nodeIsIdle $ do
      setNodeStartTime  tv nName nodeStartTime nodeStartTimeChanged els ElNodeStarttime
      setNodeUpTime nodeStartTime els ElNodeUptime

      setNodeVersion    tv nName (TextV    nodeVersion)          nodeVersionChanged        els ElNodeVersion
      setNodeProtocol   tv nName (TextV    nodeProtocol)         nodeProtocolChanged       els ElNodeProtocol
      setNodePlatform   tv nName (TextV    nodePlatform)         nodePlatformChanged       els ElNodePlatform
      setEpoch          tv nName (IntegerV epoch)                epochChanged              els ElEpoch
      setSlot           tv nName (IntegerV slot)                 slotChanged               els ElSlot
      setBlocksNumber   tv nName (IntegerV blocksNumber)         blocksNumberChanged       els ElBlocksNumber
      setChainDensity   tv nName (DoubleV  chainDensity)         chainDensityChanged       els ElChainDensity
      setForgedNum      tv nName (IntegerV blocksForgedNumber)   blocksForgedNumberChanged els ElBlocksForgedNumber
      setCannotForge    tv nName (IntegerV nodeCannotForge)      nodeCannotForgeChanged    els ElNodeCannotForge
      setNodeIsLeader   tv nName (IntegerV nodeIsLeaderNum)      nodeIsLeaderNumChanged    els ElNodeIsLeaderNumber
      setSlotsMissed    tv nName (IntegerV slotsMissedNumber)    slotsMissedNumberChanged  els ElSlotsMissedNumber
      setTxsProcessed   tv nName (IntegerV txsProcessed)         txsProcessedChanged       els ElTxsProcessed
      setMPoolTxsNum    tv nName (IntegerV mempoolTxsNumber)     mempoolTxsNumberChanged   els ElMempoolTxsNumber
      setMPoolBytes     tv nName (Word64V  mempoolBytes)         mempoolBytesChanged       els ElMempoolBytes
      setRtsGcCpu       tv nName (DoubleV  rtsGcCpu)             rtsGcCpuChanged           els ElRTSGcCpu
      setRtsGcElapsed   tv nName (DoubleV  rtsGcElapsed)         rtsGcElapsedChanged       els ElRTSGcElapsed
      setRtsGcNum       tv nName (IntegerV rtsGcNum)             rtsGcNumChanged           els ElRTSGcNum
      setRtsGcMajorNum  tv nName (IntegerV rtsGcMajorNum)        rtsGcMajorNumChanged      els ElRTSGcMajorNum
      setPeers          tv nName (IntV     $ length peersInfo)   peersInfoChanged          els ElPeersNumber
      setStartKES       tv nName (IntegerV opCertStartKESPeriod)  opCertStartKESPeriodChanged  els ElOpCertStartKESPeriod
      setExpiryKES      tv nName (IntegerV opCertExpiryKESPeriod) opCertExpiryKESPeriodChanged els ElOpCertExpiryKESPeriod
      setCurrentKES     tv nName (IntegerV currentKESPeriod)      currentKESPeriodChanged      els ElCurrentKESPeriod
      setRemKES         tv nName (IntegerV remKESPeriods)       remKESPeriodsChanged       els ElRemainingKESPeriods
      setRemKESDays     tv nName (IntegerV remKESPeriodsInDays) remKESPeriodsInDaysChanged els ElRemainingKESPeriodsInDays
      setSystemStart    tv nName systemStartTime systemStartTimeChanged els ElSystemStartTime
      setNodeCommit     tv nName nodeCommit nodeShortCommit nodeCommitChanged els ElNodeCommitHref

      updateCharts window nName rm nm

type Setter = TVar NodesState
              -> Text
              -> ElementValue
              -> Bool
              -> NodeStateElements
              -> ElementName
              -> UI ()

setNodeVersion :: Setter
setNodeVersion _ _ _ False _ _ = return ()
setNodeVersion tv nameOfNode nodeVersion True els elName =
  whenJust (els !? elName) $ \el -> do
    let nodeVersionT = pack $ elValueToStr nodeVersion
    if strip nodeVersionT `elem` supportedNodesVersions
      then void $ setElement nodeVersion el
                    #. [] # set UI.title__ ""
      else void $ setElement nodeVersion el
                    #. [UnsupportedVersion]
                    # set UI.title__ ("Unsupported node version, please use these versions only: "
                                      <> unpack showSupportedNodesVersions)
    setChangedFlag tv nameOfNode $ \ns -> ns { nodeMetrics = (nodeMetrics ns) { nodeVersionChanged = False } }

setNodeProtocol
  , setNodePlatform
  , setEpoch
  , setSlot
  , setBlocksNumber
  , setChainDensity
  , setForgedNum
  , setCannotForge
  , setNodeIsLeader
  , setSlotsMissed
  , setTxsProcessed
  , setMPoolTxsNum
  , setMPoolTxsPerc
  , setMPoolBytes
  , setMPoolBytesPerc
  , setMPoolMaxTxs
  , setMPoolMaxBytes
  , setRtsMemAlloc
  , setRtsMemUsed
  , setRtsMemUsedPerc
  , setRtsGcCpu
  , setRtsGcElapsed
  , setRtsGcNum
  , setRtsGcMajorNum
  , setPeers
  , setStartKES
  , setExpiryKES
  , setCurrentKES
  , setRemKES
  , setRemKESDays :: Setter
setNodeProtocol   = evSetter (\ns -> ns { nodeMetrics = (nodeMetrics ns) { nodeProtocolChanged = False } })
setNodePlatform   = evSetter (\ns -> ns { nodeMetrics = (nodeMetrics ns) { nodePlatformChanged = False } })
setEpoch          = evSetter (\ns -> ns { blockchainMetrics = (blockchainMetrics ns) { epochChanged        = False } })
setSlot           = evSetter (\ns -> ns { blockchainMetrics = (blockchainMetrics ns) { slotChanged         = False } })
setBlocksNumber   = evSetter (\ns -> ns { blockchainMetrics = (blockchainMetrics ns) { blocksNumberChanged = False } })
setChainDensity   = evSetter (\ns -> ns { blockchainMetrics = (blockchainMetrics ns) { chainDensityChanged = False } })
setForgedNum      = evSetter (\ns -> ns { forgeMetrics = (forgeMetrics ns) { blocksForgedNumberChanged = False } })
setCannotForge    = evSetter (\ns -> ns { forgeMetrics = (forgeMetrics ns) { nodeCannotForgeChanged    = False } })
setNodeIsLeader   = evSetter (\ns -> ns { forgeMetrics = (forgeMetrics ns) { nodeIsLeaderNumChanged    = False } })
setSlotsMissed    = evSetter (\ns -> ns { forgeMetrics = (forgeMetrics ns) { slotsMissedNumberChanged  = False } })
setTxsProcessed   = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { txsProcessedChanged     = False } })
setMPoolTxsNum    = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolTxsNumberChanged    = False } })
setMPoolTxsPerc   = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolTxsPercentChanged   = False } })
setMPoolBytes     = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolBytesChanged        = False } })
setMPoolBytesPerc = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolBytesPercentChanged = False } })
setMPoolMaxTxs    = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolMaxTxsChanged       = False } })
setMPoolMaxBytes  = evSetter (\ns -> ns { mempoolMetrics = (mempoolMetrics ns) { mempoolMaxBytesChanged     = False } })
setRtsMemAlloc    = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsMemoryAllocatedChanged = False } })
setRtsMemUsed     = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsMemoryUsedChanged      = False } })
setRtsMemUsedPerc = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsMemoryUsedPercentChanged = False } })
setRtsGcCpu       = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsGcCpuChanged           = False } })
setRtsGcElapsed   = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsGcElapsedChanged       = False } })
setRtsGcNum       = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsGcNumChanged           = False } })
setRtsGcMajorNum  = evSetter (\ns -> ns { rtsMetrics = (rtsMetrics ns) { rtsGcMajorNumChanged      = False } })
setPeers          = evSetter (\ns -> ns { peersMetrics = (peersMetrics ns) { peersInfoChanged = False } })
setStartKES       = evSetter (\ns -> ns { kesMetrics = (kesMetrics ns) { opCertStartKESPeriodChanged  = False } })
setExpiryKES      = evSetter (\ns -> ns { kesMetrics = (kesMetrics ns) { opCertExpiryKESPeriodChanged = False } })
setCurrentKES     = evSetter (\ns -> ns { kesMetrics = (kesMetrics ns) { currentKESPeriodChanged      = False } })
setRemKES         = evSetter (\ns -> ns { kesMetrics = (kesMetrics ns) { remKESPeriodsChanged         = False } })
setRemKESDays     = evSetter (\ns -> ns { kesMetrics = (kesMetrics ns) { remKESPeriodsInDaysChanged   = False } })

evSetter
  :: (NodeState -> NodeState)
  -> TVar NodesState
  -> Text
  -> ElementValue
  -> Bool
  -> NodeStateElements
  -> ElementName
  -> UI ()
evSetter _ _ _ _ False _ _ = return ()
evSetter flagSetter tv nameOfNode ev True els elName =
  whenJust (els !? elName) $ \el -> do
    -- If the value is still default one, don't display it (it's meaningless).
    let nothing = StringV none
        ev' =
          case ev of
            IntV     _ -> ev
            IntegerV i -> if i < 0    then nothing else ev
            Word64V  w -> if w == 0   then nothing else ev
            DoubleV  d -> if d < 0    then nothing else ev
            StringV  s -> if null s   then nothing else ev
            TextV    t -> if T.null t then nothing else ev
    void $ setElement ev' el
    setChangedFlag tv nameOfNode flagSetter

setElement
  :: ElementValue
  -> Element
  -> UI Element
setElement ev el = element el # set text (elValueToStr ev)

elValueToStr :: ElementValue -> String
elValueToStr (IntV     i) = show i
elValueToStr (IntegerV i) = show i
elValueToStr (Word64V  w) = show w
elValueToStr (DoubleV  d) = showWith1DecPlace d
elValueToStr (StringV  s) = s
elValueToStr (TextV    t) = unpack t

updateProgressBar
  :: Double
  -> NodeStateElements
  -> ElementName
  -> UI ()
updateProgressBar percents els elName =
  whenJust (els !? elName) $ \bar ->
    void $ element bar # set style [("width", showWith1DecPlace preparedPercents <> "%")]
 where
  -- Sometimes (for CPU usage) percents can be bigger than 100%,
  -- in this case actual width of bar should be 100%.
  preparedPercents = if percents > 100.0 then 100.0 else percents

setSystemStart
  :: TVar NodesState
  -> Text
  -> UTCTime
  -> Bool
  -> NodeStateElements
  -> ElementName
  -> UI ()
setSystemStart _ _ _ False _ _ = return ()
setSystemStart tv nameOfNode systemStart True els elName =
  whenJust (els !? elName) $ \el -> do
    void $ element el # set text systemStartFormatted
    setChangedFlag tv
                   nameOfNode
                   (\ns -> ns { blockchainMetrics = (blockchainMetrics ns) { systemStartTimeChanged = False } })
 where
  systemStartFormatted = formatTime defaultTimeLocale "%F %T %Z" systemStart

setNodeUpTime
  :: UTCTime
  -> NodeStateElements
  -> ElementName
  -> UI ()
setNodeUpTime startTime els elName =
  whenJust (els !? elName) $ \el -> do
    upTimeDiff <-
      if startTime /= nullTime
        then do
          -- nodeStartTime received from the node.
          now <- liftIO getCurrentTime
          let upTimeDiff = now `diffUTCTime` startTime
          return upTimeDiff
        else
          -- No nodeStartTime were received (yet).
          return 0

    if upTimeDiff == 0
      then
        void $ element el # set text "00:00:00"
      else do
        let upTime = upTimeDiff `addUTCTime` nullTime
            upTimeFormatted = formatTime defaultTimeLocale "%X" upTime
            daysNum = utctDay upTime `diffDays` utctDay nullTime
            upTimeWithDays = if daysNum > 0
                               -- Show days only if upTime is bigger than 23:59:59.
                               then show daysNum <> "d " <> upTimeFormatted
                               else upTimeFormatted
        void $ element el # set text upTimeWithDays

setNodeStartTime
  :: TVar NodesState
  -> Text
  -> UTCTime
  -> Bool
  -> NodeStateElements
  -> ElementName
  -> UI ()
setNodeStartTime _ _ _ False _ _ = return ()
setNodeStartTime tv nameOfNode startTime True els elName =
  whenJust (els !? elName) $ \el -> do
    if startTime /= nullTime
      then void $ element el # set text startTimeFormatted
      else void $ element el # set text none
    setChangedFlag tv
                   nameOfNode
                   (\ns -> ns { nodeMetrics = (nodeMetrics ns) { nodeStartTimeChanged = False } })
 where
  startTimeFormatted = formatTime defaultTimeLocale "%F %T %Z" startTime

setNodeCommit
  :: TVar NodesState
  -> Text
  -> Text
  -> Text
  -> Bool
  -> NodeStateElements
  -> ElementName
  -> UI ()
setNodeCommit _ _ _ _ False _ _ = return ()
setNodeCommit tv nameOfNode commit shortCommit True els elName =
  whenJust (els !? elName) $ \el -> do
    void $ element el # set children []
    void $ element el #+ [ UI.anchor # set UI.href ("https://github.com/input-output-hk/cardano-node/commit/"
                                       <> unpack commit)
                                     # set UI.target "_blank"
                                     # set UI.title__ "Browse cardano-node repository on this commit"
                                     # set UI.text (showText shortCommit)
                         ]
    setChangedFlag tv
                   nameOfNode
                   (\ns -> ns { nodeMetrics = (nodeMetrics ns) { nodeCommitChanged = False } })

-- | Since peers list will be changed dynamically, we need it
--   to update corresponding HTML-murkup dynamically as well.
--   Please note that we don't change DOM actully (to avoid possible space leak).
updatePeersList
  :: TVar NodesState
  -> Text
  -> [PeerInfo]
  -> Bool
  -> [PeerInfoItem]
  -> UI ()
updatePeersList _ _ _ False _ = return ()
updatePeersList tv nameOfNode peersInfo' True peersInfoItems = do
  -- The number of connected peers may reduce, so first of all hide all items.
  mapM_ (hideElement . piItem) peersInfoItems

  let peersInfo =
        if length peersInfo' > length peersInfoItems
          then
            -- We prepared peer items for known number of connected peers,
            -- but the number of connected peers is bigger than prepared items.
            -- Show only first N items.
            take (length peersInfoItems) peersInfo'
          else
            peersInfo'
  -- Show N items, corresponding to the number of connected peers,
  -- and fill them with actual values.
  let peersInfoWithIndices = zip peersInfo [0 .. length peersInfo - 1]
  forM_ peersInfoWithIndices $ \(PeerInfo {..}, i) -> do
    let item  = peersInfoItems L.!! i
        PeerInfoElements {..} = piItemElems item
    -- Update internal elements of item using actual values.
    void $ setElement (StringV piEndpoint)   pieEndpoint
    void $ setElement (StringV piBytesInF)   pieBytesInF
    void $ setElement (StringV piReqsInF)    pieReqsInF
    void $ setElement (StringV piBlocksInF)  pieBlocksInF
    void $ setElement (StringV piSlotNumber) pieSlotNumber
    void $ setElement (StringV piStatus)     pieStatus
    -- Make item visible.
    showElement $ piItem item
  setChangedFlag tv
                 nameOfNode
                 (\ns -> ns { peersMetrics = (peersMetrics ns) { peersInfoChanged = False } })

updateErrorsListAndTab
  :: UI.Window
  -> TVar NodesState
  -> Text
  -> [NodeError]
  -> Bool
  -> NodeStateElements
  -> ElementName
  -> ElementName
  -> ElementName
  -> ElementName
  -> UI ()
updateErrorsListAndTab _ _ _ _ False _ _ _ _ _ = return ()
updateErrorsListAndTab window tv nameOfNode nodeErrors' True els
                       elName elTabName elTabBadgeName elDownloadName = do
  let maybeEl         = els !? elName
      maybeElTab      = els !? elTabName
      maybeElTabBadge = els !? elTabBadgeName
      maybeElDownload = els !? elDownloadName
  when (   isJust maybeEl
        && isJust maybeElTab
        && isJust maybeElTabBadge
        && isJust maybeElDownload) $ do
    let el         = fromJust maybeEl
        elTab      = fromJust maybeElTab
        elTabBadge = fromJust maybeElTabBadge
        elDownload = fromJust maybeElDownload
    justUpdateErrorsListAndTab nodeErrors' el elTab elTabBadge

    unless (null nodeErrors') $ do
      void $ return window # set UI.title pageTitleNotify
      prepareCSVForDownload nodeErrors' nameOfNode elDownload

    setChangedFlag tv
                   nameOfNode
                   (\ns -> ns { nodeErrors = (nodeErrors ns) { errorsChanged = False } })

justUpdateErrorsListAndTab
  :: [NodeError]
  -> Element
  -> Element
  -> Element
  -> UI ()
justUpdateErrorsListAndTab nodeErrors' elErrors elTab elTabBadge = do
  if null nodeErrors'
    then do
      void $ element elTab # set UI.enabled False
                           # set UI.title__ errorsTabTitle
      void $ element elTabBadge # hideIt
                                # set text ""
    else do
      void $ element elTab # set UI.enabled True
                           # set UI.title__ errorsTabTitle
      void $ element elTabBadge # showInline
                                # set text (show . length $ nodeErrors')
  -- When the user filters errors in Errors tab, we don't remove them, just hide them.
  -- So only visible errors should be displayed.
  let visibleNodeErrors = filter eVisible nodeErrors'
  errors <- forM visibleNodeErrors $ \(NodeError utcTimeStamp sev msg _) -> do
    let (aClass, aTagClass, aTag, aTagTitle) =
          case sev of
            Warning   -> (WarningMessage,   WarningMessageTag,   "W", "Warning")
            Error     -> (ErrorMessage,     ErrorMessageTag,     "E", "Error")
            Critical  -> (CriticalMessage,  CriticalMessageTag,  "C", "Critical")
            Alert     -> (AlertMessage,     AlertMessageTag,     "A", "Alert")
            Emergency -> (EmergencyMessage, EmergencyMessageTag, "E", "Emergency")
            _         -> (NoClass,          NoClass,             "",  "")

    let timeStamp = formatTime defaultTimeLocale "%F %T %Z" utcTimeStamp

    UI.div #. [W3Row, ErrorRow] #+
      [ UI.div #. [W3Third, ErrorTimestamp] #+
          [ UI.string timeStamp
          ]
      , UI.div #. [W3TwoThird] #+
          [ UI.string aTag #. [aTagClass] # set UI.title__ aTagTitle
          , UI.string msg  #. [aClass]
          ]
      ]
  void $ element elErrors # set children errors
 where
  errorsTabTitle =
    case length nodeErrors' of
      0 -> "Good news: there are no errors!"
      1 -> "There is one error from node"
      n -> "There are " <> show n <> " errors from node"

prepareCSVForDownload
  :: [NodeError]
  -> Text
  -> Element
  -> UI ()
prepareCSVForDownload nodeErrors' nameOfNode el = do
  let csvFile = "cardano-rt-view-" <> T.unpack nameOfNode <> "-errors.csv"
      errorsAsCSV = mkCSVWithErrorsForHref nodeErrors'
  void $ element el # set children []
  void $ element el #+ [ UI.anchor # set UI.href ("data:application/csv;charset=utf-8," <> errorsAsCSV)
                                   # set (UI.attr "download") csvFile
                                   #+ [ UI.img #. [ErrorsDownloadIcon]
                                               # set UI.src "/static/images/file-download.svg"
                                               # set UI.title__ "Download errors as CSV"
                                      ]
                       ]

-- Check the errors for all nodes: if there's no errors at all,
-- set the page's title to default one.
resetPageTitleIfNeeded
  :: UI.Window
  -> TVar NodesState
  -> UI ()
resetPageTitleIfNeeded window tv = do
  nodesState <- liftIO $ readTVarIO tv
  noErrors <- forM (HM.elems nodesState) (return . null . errors . nodeErrors)
  when (all (True ==) noErrors) $
    void $ return window # set UI.title pageTitle

showElement, hideElement :: Element -> UI Element
showElement w = element w # set UI.style [("display", "inline")]
hideElement w = element w # set UI.style [("display", "none")]

updateCharts
  :: UI.Window
  -> Text
  -> ResourcesMetrics
  -> NodeMetrics
  -> UI ()
updateCharts window nameOfNode rm nm = do
  now <- liftIO getCurrentTime
  let ts :: String
      ts = formatTime defaultTimeLocale "%M:%S" time
      time = timeDiff `addUTCTime` nullTime
      timeDiff :: NominalDiffTime
      timeDiff = now `diffUTCTime` nodeStartTime nm

  mcId <- ifM (elementExists mN) (pure mN) (pure mGN)
  ccId <- ifM (elementExists cN) (pure cN) (pure cGN)
  dcId <- ifM (elementExists dN) (pure dN) (pure dGN)
  ncId <- ifM (elementExists nN) (pure nN) (pure nGN)

  UI.runFunction $ UI.ffi Chart.updateMemoryUsageChartJS  mcId ts (memory rm)
  UI.runFunction $ UI.ffi Chart.updateCPUUsageChartJS     ccId ts (cpuPercent rm)
  UI.runFunction $ UI.ffi Chart.updateDiskUsageChartJS    dcId ts (diskUsageR rm)     (diskUsageW rm)
  UI.runFunction $ UI.ffi Chart.updateNetworkUsageChartJS ncId ts (networkUsageIn rm) (networkUsageOut rm)
 where
  mN = showt MemoryUsageChartId  <> nameOfNode
  cN = showt CPUUsageChartId     <> nameOfNode
  dN = showt DiskUsageChartId    <> nameOfNode
  nN = showt NetworkUsageChartId <> nameOfNode

  mGN = showt GridMemoryUsageChartId  <> nameOfNode
  cGN = showt GridCPUUsageChartId     <> nameOfNode
  dGN = showt GridDiskUsageChartId    <> nameOfNode
  nGN = showt GridNetworkUsageChartId <> nameOfNode

  showt :: Show a => a -> Text
  showt = pack . show

  elementExists anId = isJust <$> UI.getElementById window (unpack anId)

-- | If no metrics was received from the node for a long time
--   (more than 'active-node-life') this node is treated as idle.
--   Technically it means that the node is disconnected from RTView
--   or it wasn't connected to RTView at all.
checkIfNodeIsIdlePane
  :: RTViewParams
  -> Word64
  -> Element
  -> Element
  -> UI Bool
checkIfNodeIsIdlePane params metricsLastUpdate idleTag nodePane =
  checkIfNodeIsIdle params
                    metricsLastUpdate
                    idleTag
                    (void $ element nodePane # set UI.style [("opacity", "0.7")])
                    (void $ element nodePane # set UI.style [("opacity", "1.0")])

checkIfNodeIsIdleGrid
  :: UI.Window
  -> RTViewParams
  -> Word64
  -> Element
  -> Text
  -> UI Bool
checkIfNodeIsIdleGrid window params metricsLastUpdate idleTag nameOfNode =
  checkIfNodeIsIdle params
                    metricsLastUpdate
                    idleTag
                    (forNodeColumn $ set UI.style [("opacity", "0.7")])
                    (forNodeColumn $ set UI.style [("opacity", "1.0")])
 where
  forNodeColumn
    :: (UI Element -> UI Element)
    -> UI ()
  forNodeColumn action = do
    let cellsIdsForNodeColumn =
          map (\elemName -> show elemName <> "-" <> unpack nameOfNode)
              allMetricsNames
    let allCells = (show GridNodeTH <> unpack nameOfNode) : cellsIdsForNodeColumn
    forM_ allCells $ \anId ->
      whenJustM (UI.getElementById window anId) $ \el ->
        void $ element el # action

checkIfNodeIsIdle
  :: RTViewParams
  -> Word64
  -> Element
  -> UI ()
  -> UI ()
  -> UI Bool
checkIfNodeIsIdle RTViewParams {..}
                  metricsLastUpdate
                  idleTag
                  additionalActionOnIdle
                  additionalActionOnActive = do
  let lifetimeInNSec = secToNanosec rtvActiveNodeLife
  now <- liftIO getMonotonicTimeNSec
  if now - metricsLastUpdate > lifetimeInNSec
    then do
      markNodeAsIdle
      return True
    else do
      markNodeAsActive
      return False
 where
  secToNanosec :: Int -> Word64
  secToNanosec s = fromIntegral $ s * 1000000000
  markNodeAsIdle = do
    void $ showElement idleTag # set UI.title__ ("Node metrics have not been received for more than "
                                                 <> show rtvActiveNodeLife <> " seconds")
    additionalActionOnIdle
  markNodeAsActive = do
    void $ hideElement idleTag # set UI.title__ ""
    additionalActionOnActive

-- | After we updated the value of DOM-element, we set 'changed'-flag
--   to False to avoid useless re-update by the same value.
setChangedFlag
  :: TVar NodesState
  -> Text
  -> (NodeState -> NodeState)
  -> UI ()
setChangedFlag nsTVar nameOfNode mkNewNS =
  liftIO . atomically $ modifyTVar' nsTVar $ \currentNS ->
    case currentNS !? nameOfNode of
      Just ns -> HM.adjust (const $ mkNewNS ns) nameOfNode currentNS
      Nothing -> currentNS
