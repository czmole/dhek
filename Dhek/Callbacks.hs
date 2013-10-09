{-# LANGUAGE DoAndIfThenElse #-}
module Dhek.Callbacks where

import Prelude hiding (foldr)
import Control.Lens
import Control.Monad (when, void)
import Control.Monad.State (execState, evalState, execStateT)
import Control.Monad.Trans (liftIO)
import Data.Aeson (encode, eitherDecode)
import Data.Char (isSpace)
import Data.IORef (IORef, newIORef, readIORef, modifyIORef, writeIORef)
import Data.Foldable (traverse_, foldMap, foldr)
import Data.Functor ((<$))
import qualified Data.ByteString.Lazy as B
import qualified Data.IntMap as I
import Data.List (dropWhileEnd)
import Dhek.Action
import Dhek.Types
import Dhek.Utils
import Data.Maybe (fromJust, isJust, isNothing)
import Data.Monoid (First(..), Sum(..))
import Graphics.UI.Gtk

onPrevious :: String -- pdf filename
           -> Window
           -> Button -- prev button
           -> Button -- next button
           -> ListStore Rect
           -> IO ()
           -> IORef Viewer
           -> IO ()
onPrevious name win = onNavCommon name win onPrevState

onNext :: String -- pdf filename
       -> Window
       -> Button -- next button
       -> Button -- prev button
       -> ListStore Rect
       -> IO ()
       -> IORef Viewer
       -> IO ()
onNext name win = onNavCommon name win onNextState

onNavCommon :: String
            -> Window
            -> (Int -> Int -> (Bool, Bool, Int))
            -> Button
            -> Button
            -> ListStore Rect
            -> IO ()
            -> IORef Viewer
            -> IO ()
onNavCommon name win upd self other store redraw ref =
    readIORef ref >>= \v ->
        let nb = v ^. viewerPageCount
            (tSelf, tOther, v') = onNavButton upd v
            cur = v' ^. viewerCurrentPage
            title = name ++ " (page " ++ show cur ++" / " ++ show nb ++ ")"
            board = viewerBoards.boardsMap.at cur.traverse.boardRects
            rects = v ^. board.to I.elems in
        do listStoreClear store
           traverse_ (listStoreAppend store) rects
           widgetSetSensitive self (not tSelf)
           when tOther (widgetSetSensitive other True)
           writeIORef ref v'
           windowSetTitle win title
           redraw

onJsonSave :: IORef Viewer
           -> FileChooserDialog
           -> ResponseId
           -> IO ()
onJsonSave _ jfch ResponseCancel = widgetHide jfch
onJsonSave ref jfch ResponseOk =
    readIORef ref >>= \v ->
        let nb          = v ^. viewerPageCount
            tup (i, b)  = (i, b ^. boardRects.to I.elems)
            toList      = fmap tup . I.toList
            rects       = v ^. viewerBoards.boardsMap.to toList
            save        = saveNew $ fillUp nb rects
            ensure path
                | takeExtension path == ".json" = path
                | otherwise                     = path ++ ".json"
            write path  = B.writeFile (ensure path) (encode save) in
        do opt <- fileChooserGetFilename jfch
           traverse_ write opt
           widgetHide jfch

onJsonImport :: IORef Viewer
             -> IO ()
             -> ListStore Rect
             -> FileChooserDialog
             -> ResponseId
             -> IO ()
onJsonImport _ _ _ ifch ResponseCancel = widgetHide ifch
onJsonImport ref redraw store ifch ResponseOk = do
  opt  <- fileChooserGetFilename ifch
  bOpt <- traverse go opt
  traverse_ (traverse_ updViewer) bOpt
    where
      go path = do
        bytes <- B.readFile path
        let boardsE = fmap saveToBoards (eitherDecode bytes)
        either showError (return . Just) boardsE

      showError e = do
        p <- windowGetTransientFor ifch
        m <- messageDialogNew p [DialogModal] MessageError ButtonsOk e
        dialogRun m
        widgetHide m
        return Nothing

      updViewer boards = do
        v <- readIORef ref
        let v'    = v & viewerBoards .~ boards
            page  = v ^. viewerCurrentPage
            rects = boards ^. boardsMap.at page.traverse.boardRects.to I.elems
        writeIORef ref v'
        listStoreClear store
        traverse_ (listStoreAppend store) rects
        widgetHide ifch
        redraw

onCommonScale :: (Int -> Int)
              -> Button -- minus button
              -> Button -- plus button
              -> IO ()
              -> IORef Viewer
              -> IO ()
onCommonScale upd minus plus redraw ref =
    readIORef ref >>= \v ->
        let z   = v ^. viewerZoom.to upd
            low = (z-1) < 0
            up  = (z+1) > 10
            v'  = v & viewerZoom .~ z in
        do widgetSetSensitive minus (not low)
           widgetSetSensitive plus (not up)
           writeIORef ref v'
           redraw

onTreeSelection :: TreeSelection
                -> ListStore Rect
                -> IO ()
                -> IORef Viewer
                -> IO ()
onTreeSelection sel store redraw ref = do
  opt  <- treeSelectionGetSelected sel
  rOpt <- traverse (listStoreGetValue store . listStoreIterToIndex) opt
  v    <- readIORef ref
  let v' = v & viewerBoards.boardsSelected .~ rOpt
  writeIORef ref v'
  redraw

onRemoveArea :: TreeSelection
             -> ListStore Rect
             -> IO ()
             -> IORef Viewer
             -> IO ()
onRemoveArea sel store redraw ref = do
  v   <- readIORef ref
  opt <- treeSelectionGetSelected sel
  traverse_ (delete v) opt
    where
      delete v i =
          let idx   = listStoreIterToIndex i
              page  = v ^. viewerCurrentPage
              board = viewerBoards.boardsMap.at page.traverse.boardRects in
          do r <- listStoreGetValue store idx
             let id = r ^. rectId
                 v' = v & board.at id .~ Nothing
             listStoreRemove store idx
             writeIORef ref v'
             redraw

type PdfCallback = FileChooserDialog
                 -> MenuItem -- Import item
                 -> MenuItem -- Export item
                 -> Window
                 -> IO HBox

openPdfFileChooser :: PdfCallback
                   -> VBox
                   -> FileChooserDialog
                   -> Window
                   -> MenuItem
                   -> MenuItem
                   -> MenuItem
                   -> IO ()
openPdfFileChooser k vbox dialog win mopen mimport msave = do
  resp <- dialogRun dialog
  widgetHide dialog
  case resp of
    ResponseCancel -> return ()
    ResponseOk     -> do
      avbox <- alignmentNew 0 0 1 1
      vvbox <- k dialog mimport msave win
      containerAdd avbox vvbox
      boxPackStart vbox avbox PackGrow 0
      widgetSetSensitive mopen False
      widgetShowAll avbox

onMove :: ViewerRef -> EventM EMotion ()
onMove ref = do
    frame   <- eventWindow
    (x',y') <- eventCoordinates
    liftIO $ do
        ratio <- viewerGetRatio ref
        let (x,y) = (x'/ratio, y'/ratio)
        oOpt <- viewerGetOvered ref
        dOpt <- viewerGetOveredRect ref x y
        viewerSetOvered ref dOpt
        viewerModifySelection ref (updateSelection x y)
        viewerModifyEvent ref (updateEvent x y)
        sOpt <- viewerGetSelection ref
        evt  <- viewerGetEvent ref
        let onEvent     = isJust $ eventGetRect evt
            onSelection = isJust sOpt
            changed     = (oOpt /= dOpt) || onEvent || onSelection
            cursor      = if isJust dOpt && not onSelection
                          then Hand1
                          else Tcross
        when changed $ do
                        c <- cursorNew cursor
                        drawWindowSetCursor frame (Just c)
                        viewerDraw ref

onPress :: ViewerRef -> EventM EButton ()
onPress ref = do
    b <- eventButton
    c <- eventClick
    when (b == LeftButton && c == SingleClick) go
  where
    go = do
        (x', y') <- eventCoordinates
        liftIO $ do
             ratio <- viewerGetRatio ref
             let (x,y)   = (x'/ratio, y'/ratio)
                 sel     = rectNew x y 0 0
                 onEvt r = do
                     aOpt <- viewerGetOveredArea ref x y r
                     let evt = maybe (Hold r (x,y)) (Resize r (x,y)) aOpt
                     viewerSetEvent ref evt
                     viewerSelectRect ref r
                     viewerSetSelected ref (Just r)
             oOpt <- viewerGetOveredRect ref x y
             maybe (viewerSetSelection ref sel) onEvt oOpt

onRelease :: ViewerRef -> EventM EButton ()
onRelease ref = do
    b <- eventButton
    when (b == LeftButton) (liftIO go)
  where
    go = do
        evt <- viewerGetEvent ref
        sel <- viewerGetSelection ref
        traverse_ insert sel
        traverse_ (upd . normalize) (eventGetRect evt)
        viewerDraw ref

    upd r = do
        viewerSetRect ref r
        viewerSelectRect ref r

    insert x =
        let x' = normalize x
            w  = x' ^. rectWidth
            h  = x' ^. rectHeight in
        if (w*h >= 30)
        then viewerInsertRect ref x'
        else viewerClearSelection ref

updateSelection :: Double -> Double -> Rect -> Rect
updateSelection x y = execState go
  where
    go = do
        x0 <- use rectX
        y0 <- use rectY
        rectWidth  .= x - x0
        rectHeight .= y - y0

updateEvent :: Double -> Double -> BoardEvent -> BoardEvent
updateEvent x y e =
    case e of
      Hold r (x0,y0)     -> Hold (translateRect (x-x0) (y-y0) r) (x,y)
      Resize r (x0,y0) a -> Resize (resizeRect (x-x0) (y-y0) a r) (x,y) a

onPropAreaSelection :: Entry -> ListStore String -> ComboBox -> Rect -> IO ()
onPropAreaSelection entry store combo r = do
  entrySetText entry (r ^. rectName)
  let pred x = x == (r ^. rectType)
  opt <- lookupStoreIter pred store
  traverse_ (comboBoxSetActiveIter combo) opt

onPropClear :: Entry -> ComboBox -> IO ()
onPropClear entry combo = do
  entrySetText entry ""
  comboBoxSetActive combo (negate 1)

-- onPropUpdate :: Window
--              -> ListStore Rect
--              -> Entry
--              -> ComboBox
--              -> IORef Viewer
--              -> IO ()
-- onPropUpdate win rectStore entry combo ref = do
--   v <- readIORef ref
--   let page     = v ^. viewerCurrentPage
--       selOpt   = v ^. viewerBoards.boardsSelected
--       board    = v ^. viewerBoards.boardsMap.at page.traverse
--       toRect i = board ^. boardRects.at i
--       rectOpt  = selOpt >>= toRect
--   traverse_ (go page v) rectOpt
--     where
--       go page v r = do
--           name' <- entryGetText entry
--           let name     = trimStr name'
--               emptyStr = null name
--           when (not emptyStr) (onValidStr page v r name)

--       onValidStr page v r name = do
--           nOpt  <- lookupStoreIter ((== name) . _rectName) rectStore
--           let exist = isJust nOpt
--           typeOpt <- comboBoxGetActiveText combo
--           when exist (showError ("\"" ++ name ++ "\" is used"))
--           when (not exist) (traverse_ (upd page v r name) typeOpt)

--       showError e = do
--           m <- messageDialogNew (Just win) [DialogModal] MessageError ButtonsOk e
--           dialogRun m
--           widgetHide m

--       upd page v r name typ =
--           let id = r ^. rectId
--               r' = r & rectName .~ name & rectType .~ typ
--               b  = v ^. viewerBoards.boardsMap.at page.traverse
--               b' = b & boardRects.at id ?~ r'
--               v' = v & viewerBoards.boardsMap.at page ?~ b' in
--           do writeIORef ref v'
--              listStoreClear rectStore
--              traverse_ (listStoreAppend rectStore) (b' ^. boardRects.to I.elems)

-- onPropEntryActivated :: ViewerRef -> String -> IO ()
-- onPropEntryActivated ref name = do
--     rOpt <- viewerLookupIter ((== name) . _rectName)
--     let exist = isJust rOpt

trimStr :: String -> String
trimStr = dropWhileEnd isSpace . dropWhile isSpace

lookupStoreIter :: (a -> Bool) -> ListStore a -> IO (Maybe TreeIter)
lookupStoreIter pred store = treeModelGetIterFirst store >>= go
    where
      go (Just it) = do
        a <- listStoreGetValue store (listStoreIterToIndex it)
        if pred a
        then return (Just it)
        else treeModelIterNext store it >>= go
      go _ = return Nothing
