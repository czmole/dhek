module Dhek.Move where

import Control.Applicative ((<|>), (<$))
import Control.Lens (use, (.=), (%=), (?=), (+=), (-=), (<%=), (^.), (&), (.~), (%~), (-~), (+~))
import Control.Monad ((<=<), when)
import Control.Monad.Reader (ask)
import Control.Monad.State (execState)

import Data.Foldable (foldMap, for_, traverse_)
import Data.Maybe (isJust, fromMaybe)
import Data.Monoid (First(..))
import Data.Traversable (traverse)

import Dhek.Engine
import Dhek.Instr
import Dhek.Types hiding (addRect)

import Debug.Trace

onMove :: DhekProgram ()
onMove = compile $ do
    (x,y)   <- getPointer
    oOpt    <- getOverRect
    aOpt    <- getOverArea
    sOpt    <- getSelection
    eOpt'   <- getEvent
    lOpt    <- getCollision
    overlap <- isActive Overlap
    bidon   <- getBidon
    when bidon (setBidon False)

    let eOpt = bool bidon Nothing eOpt'
        onEvent   = isJust eOpt
        selection = do
             x0 <- use rectX
             y0 <- use rectY
             rectWidth  .= x - x0
             rectHeight .= y - y0

        event (Hold r (x0,y0))     =
            Hold (translateRect (x-x0) (y-y0) r) (x,y)
        event (Resize r (x0,y0) a) =
            Resize (resizeRect (x-x0) (y-y0) a r) (x,y) a

        eventD NORTH (Hold r (x0,y0)) =
            Hold (translateRectX (x-x0) r) (x,y0)
        eventD SOUTH (Hold r (x0,y0)) =
            Hold (translateRectX (x-x0) r) (x,y0)
        eventD WEST (Hold r (x0,y0)) =
            Hold (translateRectY (y-y0) r) (x0,y)
        eventD EAST (Hold r (x0,y0)) =
            Hold (translateRectY (y-y0) r) (x0,y)
        eventD _ e = event e

        cOpt = fmap eventCursor eOpt <|>
               fmap areaCursor aOpt  <|>
               handCursor <$ oOpt

        eOpt2 = fmap event eOpt
        sOpt2 = fmap (execState selection) sOpt

        onCollisionActivated = do
            rs <- getRects
            for_ (eOpt2 >>= eventGetRect) $ \l ->
                for_ (intersection rs l) $ \(r, d) -> do
                    let (rmin, rmax) = rectRange d r
                        (delta, l1)  = replaceRect d l r
                        (x1, y1)     =
                            case d of
                                NORTH -> (x, y-delta)
                                WEST  -> (x-delta, y)
                                SOUTH -> (x, y+delta)
                                EAST  -> (x+delta, y)

                        opp = oppositeDirection d
                        de  = fromEdge opp (x1,y1) l1

                    setCollision $ Just (x1,y1,de,rmin,rmax,d)
                    setEventRect l1

        prevCollision (x0,y0,de,rmin,rmax,d) = do
            let delta =
                    case d of
                        NORTH -> y-y0
                        SOUTH -> y0-y
                        WEST  -> x-x0
                        EAST  -> x0-x

                doesCollides l =
                    let lx = l ^. rectX
                        ly = l ^. rectY
                        lw = l ^. rectWidth
                        lh = l ^. rectHeight in
                    case d of
                        NORTH -> rmin <= (lx+lw) && lx <= rmax
                        SOUTH -> rmin <= (lx+lw) && lx <= rmax
                        EAST  -> rmin <= (ly+lh) && ly <= rmax
                        WEST  -> rmin <= (ly+lh) && ly <= rmax

                correct NORTH (Hold r (px,py)) =
                     Hold (r & rectY .~ y0+de) (px, y0+de)
                correct SOUTH (Hold r (px, py)) =
                    Hold (r & rectY .~ y0-de) (px, y0-de)
                correct WEST (Hold r (px,py)) =
                    Hold (r & rectX .~ x0+de) (x0+de, py)
                correct EAST (Hold r (px,py)) =
                    Hold (r & rectX .~ x0-de) (x0-de, py)
                correct _ e = e

                debug = "BEGIN --\n" ++
                        "cur: " ++ show (x,y) ++ "\n" ++
                        "de: " ++ show de ++ "\n" ++
                        "colPos: " ++ show (x0,y0) ++ "\n" ++
                        "colRange: " ++ show(rmin, rmax) ++ "\n" ++
                        "delta: " ++ show delta ++ "\n" ++
                        "collides: " ++ show collides ++ "\n" ++
                        "direction: " ++ show d ++ "\nEND"

                catchUp  = trace debug (delta <= 0)
                eOpt3    = fmap (eventD d) eOpt
                eOpt4    = fmap (correct d) eOpt3
                collides = maybe False doesCollides (eOpt3 >>= eventGetRect)
            setEvent eOpt3
            when (catchUp || not collides) $ do
                when catchUp $ do
                    setEvent eOpt4
                    setBidon True
                setCollision Nothing

        noPrevCollision = do
            setEvent eOpt2
            when (onEvent && not overlap) onCollisionActivated

    setSelection sOpt2
    maybe noPrevCollision prevCollision lOpt
    setCursor cOpt
    when (isJust sOpt || isJust eOpt) draw

onPress :: DhekProgram ()
onPress = compile $ do
    (x,y) <- getPointer
    oOpt  <- getOverRect
    aOpt  <- getOverArea
    let newSel = rectNew x y 0 0
        onEvent aOpt r = do
            let evt = maybe (Hold r (x,y)) (Resize r (x,y)) aOpt
            setEvent (Just evt)
            detachRect r

    maybe (setSelection (Just newSel)) (onEvent aOpt) oOpt
    draw

onRelease :: DhekProgram ()
onRelease = compile $ do
    sOpt <- getSelection
    eOpt <- getEvent
    traverse_ update eOpt
    traverse_ insert sOpt
    when (isJust eOpt || isJust sOpt) draw
  where
    update e =
        let r0 = case e of
                Hold x _     -> x
                Resize x _ _ -> x
            r  = normalize r0 in
        do attachRect r
           setSelected (Just r)
           setEvent Nothing
           setCollision Nothing

    insert r0 =
        let r1 = normalize r0
            w  = r1 ^. rectWidth
            h  = r1 ^. rectHeight in
        do when (w*h >= 30) $ do
               id <- freshId
               let r2 =  r1 & rectId   .~ id
                            & rectName %~ (++ show id)
               addRect r2
               setSelected (Just r2)
           setSelection Nothing

resizeRect :: Double -> Double -> Area -> Rect -> Rect
resizeRect dx dy area r = execState (go area) r
  where
    go TOP_LEFT = do
        rectX += dx
        rectY += dy
        rectWidth  -= dx
        rectHeight -= dy
    go TOP = do
        rectY += dy
        rectHeight -= dy
    go TOP_RIGHT = do
        rectY += dy
        rectWidth  += dx
        rectHeight -= dy
    go RIGHT = do
        rectWidth += dx
    go BOTTOM_RIGHT = do
        rectWidth += dx
        rectHeight += dy
    go BOTTOM = do
        rectHeight += dy
    go BOTTOM_LEFT = do
        rectX += dx
        rectWidth -= dx
        rectHeight += dy
    go LEFT = do
        rectX += dx
        rectWidth -= dx

replaceRect :: Direction -> Rect -> Rect -> (Double, Rect)
replaceRect d l r  = r1
  where
    lx = l ^. rectX
    ly = l ^. rectY
    lw = l ^. rectWidth
    lh = l ^. rectHeight

    rx = r ^. rectX
    ry = r ^. rectY
    rw = r ^. rectWidth
    rh = r ^. rectHeight

    r1 =
        case d of
            NORTH -> let e = ly + lh - ry in (e, l & rectY -~ e)
            WEST  -> let e = lx + lw - rx in (e, l & rectX -~ e)
            SOUTH -> let e = ry + rh - ly in (e, l & rectY +~ e)
            EAST  -> let e = rx + rw - lx in (e, l & rectX +~ e)

intersection :: [Rect] -> Rect -> Maybe (Rect, Direction)
intersection rs l = getFirst $ foldMap (First . go) rs
  where
    go r = do
        dir <- rectIntersect l r
        return (r, dir)

rectRange :: Direction -> Rect -> (Double, Double)
rectRange d r =
    case d of
        NORTH -> (x, x+w)
        EAST  -> (y, y+h)
        SOUTH -> (x, x+w)
        WEST  -> (y, y+h)
  where
    x = r ^. rectX
    y = r ^. rectY
    w = r ^. rectWidth
    h = r ^. rectHeight

fromEdge :: Direction -> (Double, Double) -> Rect -> Double
fromEdge d (x,y) r =
    case d of
        NORTH -> y - ry
        SOUTH -> y - (ry+rh)
        WEST  -> x - rx
        EAST  -> x - (rx+rw)
  where
    rx = r ^. rectX
    ry = r ^. rectY
    rw = r ^. rectWidth
    rh = r ^. rectHeight
