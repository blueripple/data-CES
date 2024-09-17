{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE DerivingVia         #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE FlexibleInstances   #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE PolyKinds           #-}
{-# LANGUAGE TypeFamilies        #-}
{-# LANGUAGE TypeOperators       #-}
{-# LANGUAGE TypeApplications    #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -O0              #-}
module BlueRipple.Data.CES
  (
    module BlueRipple.Data.CES
  , module BlueRipple.Data.CES_Frame
  )
  where

--import           BlueRipple.Data.DataFrames
import qualified BlueRipple.Data.Small.DataFrames    as BR
import qualified BlueRipple.Data.Types.Demographic as DT
import qualified BlueRipple.Data.Types.Election as ET
import qualified BlueRipple.Data.Types.Geographic as GT
import qualified BlueRipple.Data.Types.Modeling as MT
import qualified BlueRipple.Data.CountFolds as BR
import qualified BlueRipple.Data.LoadersCore as BR
import qualified BlueRipple.Data.Small.Loaders as BR
import           BlueRipple.Data.CES_Frame hiding (CES)
import qualified BlueRipple.Data.CES_Frame as CES
import qualified BlueRipple.Data.CachingCore as BR

import           Control.Lens                   ((%~))
import qualified Data.Text                     as T

import qualified Data.Vinyl                    as V
import qualified Data.Vinyl.TypeLevel          as V

import qualified Flat

import qualified Frames                        as F
import Frames ((:.))
import qualified Frames.InCore                 as FI
import qualified Frames.Melt                   as F
import qualified Frames.MapReduce              as FMR
import qualified Frames.Transform              as FT
import qualified Frames.MaybeUtils             as FM
import qualified Frames.SimpleJoins             as FJ

import qualified Frames.Visualization.VegaLite.Data
                                               as FV
import qualified Graphics.Vega.VegaLite        as GV

import qualified Data.Vector                   as V

import qualified Knit.Report as K
import qualified Relude.Extra as Relude

type MHouseVoteParty = "HouseVote" F.:-> MT.MaybeData ET.PartyT
type MPresVoteParty = "PresVote" F.:-> MT.MaybeData ET.PartyT

type CES = F.Record CESR
type CESR = [BR.Year
            , CESCaseId
            , CESPreWeight
            , CESPostWeight
            , CESVVPreWeight
            , CESVVPostWeight
            , GT.StateAbbreviation
            , GT.CongressionalDistrict
            , DT.Age5C
            , DT.SimpleAgeC
            , DT.SexC
            , DT.EducationC
            , DT.CollegeGradC
            , DT.Race5C
            , DT.SimpleRaceC
            , DT.HispC
            , DT.EvangelicalC
            , PartisanId3
            , PartisanId7
            , VRegistrationC
            , VTurnoutC
            , MHouseVoteParty
            ]

-- presidential election year
type CESPR = CESR V.++ '[MPresVoteParty]
type CESP = F.Record CESPR

type FixHouseVote rs = F.RDelete CESHouseVote rs V.++ '[MCESHouseVote]
type FixPresVote rs = F.RDelete CESPresVote rs V.++ '[MCESPresVote]

type FixBoth rs = FixPresVote (FixHouseVote rs)

cesLoaderAll :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESR))
cesLoaderAll = do
  ces2022_C <- cesLoader CES2022
  ces2020_C <- cesLoader CES2020
  ces2018_C <- cesLoader CES2018
  ces2016_C <- cesLoader CES2016
  let ces_C = mconcat <$> sequenceA [ces2022_C, ces2020_C, ces2018_C, ces2016_C]
  return $ ces_C

-- rcast to remove any year-specific fields
cesLoader :: (K.KnitEffects r, BR.CacheEffects r) => SurveyYear -> K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESR))
cesLoader cy = case cy of
    CES2022 -> fmap F.rcast <<$>> ces22Loader
    CES2020 -> fmap F.rcast <<$>> ces20Loader
    CES2018 -> fmap F.rcast <<$>> ces18Loader
    CES2016 -> fmap F.rcast <<$>> ces16Loader


ces22Loader :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESR))
ces22Loader = K.wrapPrefix "ces22Loader" $ do
  let cacheKey = "data/ces_2022.bin"
  let fixCES22 :: F.Rec (Maybe F.:. F.ElField) (F.RecordColumns CES22) -> F.Rec (Maybe F.:. F.ElField) (FixHouseVote (F.RecordColumns CES22))
      fixCES22 = fixCESCLInt . fixCES
  K.logLE (K.Debug 3) "Loading/Re-building CES 2022 data"
  stateXWalk_C <- BR.stateAbbrCrosswalkLoader
  ces22FileDep <- K.fileDependency (toString ces2018CSV)
  let deps = (,) <$> stateXWalk_C <*> ces22FileDep
  BR.retrieveOrMakeFrame cacheKey deps $ \(stateXWalk, _) -> do
    K.logLE K.Diagnostic "Re-building CES 2022 data"
    allButStateAbbrevs <- BR.maybeFrameLoader  @(F.RecordColumns CES22)
                          (BR.LocalData $ toText ces2022CSV)
                          (Just cES22Parser)
                          Nothing
                          fixCES22
                          (transformCESTargetSmart . transformCES 2022 True)
    addStateAbbreviations stateXWalk allButStateAbbrevs

ces20Loader :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESPR))
ces20Loader = K.wrapPrefix "ces20Loader" $ do
  let cacheKey = "data/ces_2020.bin"
  let fixCES20 :: F.Rec (Maybe F.:. F.ElField) (F.RecordColumns CES20) -> F.Rec (Maybe F.:. F.ElField) (FixBoth (F.RecordColumns CES20))
      fixCES20 r = fixPresVote
                   $ fixCESCLInt @(FixHouseVote (F.RecordColumns CES20))
                   $ fixCES  r
      transformCES20 = transformCESCLInt . transformCES 2020 False .
                       (FT.addOneFromOne @MCESPresVote @MPresVoteParty $ intToPresParty ET.Democratic ET.Republican)
  K.logLE (K.Debug 3) "Loading/Re-building CES 2020 data"
  stateXWalk_C <- BR.stateAbbrCrosswalkLoader
  ces20FileDep <- K.fileDependency (toString ces2020CSV)
  let deps = (,) <$> stateXWalk_C <*> ces20FileDep
  BR.retrieveOrMakeFrame cacheKey deps $ \(stateXWalk, _) -> do
    K.logLE K.Info "Rebuilding CES 2020 data"
    allButStateAbbrevs <- BR.maybeFrameLoader  @(F.RecordColumns CES20)
                          (BR.LocalData $ toText ces2020CSV)
                          (Just cES20Parser)
                          Nothing
                          fixCES20
                          transformCES20
    addStateAbbreviations stateXWalk allButStateAbbrevs

ces18Loader :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESR))
ces18Loader = K.wrapPrefix "ces18Loader" $ do
  let cacheKey = "data/ces_2018.bin"
  let fixCES18 :: F.Rec (Maybe F.:. F.ElField) (F.RecordColumns CES18) -> F.Rec (Maybe F.:. F.ElField) (FixHouseVote (F.RecordColumns CES18))
      fixCES18 = fixCESCLInt . fixCES
  K.logLE (K.Debug 3) "Loading/Re-building CES 2018 data"
  stateXWalk_C <- BR.stateAbbrCrosswalkLoader
  ces18FileDep <- K.fileDependency (toString ces2018CSV)
  let deps = (,) <$> stateXWalk_C <*> ces18FileDep
  BR.retrieveOrMakeFrame cacheKey deps $ \(stateXWalk, _) -> do
    K.logLE K.Diagnostic "Re-building CES 2018 data"
    allButStateAbbrevs <- BR.maybeFrameLoader  @(F.RecordColumns CES18)
                          (BR.LocalData $ toText ces2018CSV)
                          (Just cES18Parser)
                          Nothing
                          fixCES18
                          (transformCESCLInt . transformCES 2018 False)
    addStateAbbreviations stateXWalk allButStateAbbrevs


ces16Loader :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CESPR))
ces16Loader = K.wrapPrefix "ces16Loader" $ do
  let cacheKey = "data/ces_2016.bin"
  K.logLE (K.Debug 3) "Loading/Building CES 2016 data"
  let fixCES16 :: F.Rec (Maybe F.:. F.ElField) (F.RecordColumns CES16) -> F.Rec (Maybe F.:. F.ElField) (FixBoth (F.RecordColumns CES16))
      fixCES16 = fixPresVote . fixCESCLText @(FixHouseVote (F.RecordColumns CES16)) . fixCES
      transformCES16 = transformCESCLText . transformCES 2016 False
                       . (FT.addOneFromOne @MCESPresVote @MPresVoteParty $ intToPresParty ET.Republican ET.Democratic)
  stateXWalk_C <- BR.stateAbbrCrosswalkLoader
  ces16FileDep <- K.fileDependency (toString ces2016CSV)
  let deps = (,) <$> stateXWalk_C <*> ces16FileDep
  BR.retrieveOrMakeFrame cacheKey deps $ \(stateXWalk, _) -> do
    K.logLE K.Diagnostic "Re-building CES 2016 data"
    allButStateAbbrevs <- BR.maybeFrameLoader  @(F.RecordColumns CES16)
                          (BR.LocalData $ toText ces2016CSV)
                          (Just cES16Parser)
                          Nothing
                          fixCES16
                          transformCES16
    addStateAbbreviations stateXWalk allButStateAbbrevs

intToPresParty :: ET.PartyT -> ET.PartyT -> MT.MaybeData Int -> MT.MaybeData ET.PartyT
intToPresParty p1 p2 mn = fmap f mn where
  f n = case n of
    1 -> p1
    2 -> p2
    _ -> ET.Other

addStateAbbreviations :: forall qs rs r. (F.ElemOf rs GT.StateFIPS
                                         , F.ElemOf (rs V.++ '[GT.StateAbbreviation]) GT.StateFIPS
                                         , V.RMap rs
                                         , V.RMap (rs V.++ '[GT.StateAbbreviation])
                                         , FI.RecVec (rs V.++ '[GT.StateAbbreviation])
                                         , FI.RecVec rs
                                         , rs F.⊆ (rs V.++ '[GT.StateAbbreviation])
                                         , qs F.⊆ (rs V.++ '[GT.StateAbbreviation])
                                         , K.KnitEffects r)
                      => F.FrameRec [GT.StateName, GT.StateFIPS, GT.StateAbbreviation, GT.CensusRegionC, GT.CensusDivisionC, BR.OneDistrict, BR.SLDUpperOnly]
                      -> F.FrameRec rs
                      -> K.Sem r (F.FrameRec qs)
addStateAbbreviations stateXWalk allButStateAbbrevs = do
  let (withStateAbbreviations, missingStateFIPS) = FJ.leftJoinWithMissing @'[GT.StateFIPS] allButStateAbbrevs
                                                   $ fmap (F.rcast @[GT.StateFIPS, GT.StateAbbreviation]) stateXWalk
  unless (null missingStateFIPS)
    $ K.knitError $ "Missing state FIPS when joining CES2020 data with state crosswalk: " <> show missingStateFIPS
  return $ fmap F.rcast withStateAbbreviations

fixCES :: (F.ElemOf rs CESPreWeight
          , F.ElemOf rs CESPostWeight
--          , F.ElemOf rs CESRegisteredWeight
          , F.ElemOf rs CESHispanic
          , F.ElemOf rs CESPewBornagain
          , F.ElemOf rs CESPid3
          , F.ElemOf rs CESPid7
          , F.ElemOf rs CESEduc
          , F.ElemOf rs CESHouseVote
          , (F.RDelete CESHouseVote rs) F.⊆ rs
          )
       => F.Rec (Maybe F.:. F.ElField) rs
       -> F.Rec (Maybe F.:. F.ElField) (FixHouseVote rs)
fixCES r = fixHouseVote
           $ (F.rsubset %~ missingPreWeight)
           $ (F.rsubset %~ missingPostWeight)
--           $ (F.rsubset %~ missingRegWeight)
           $ (F.rsubset %~ missingHispanicToNo)
           $ (F.rsubset %~ missingEvangelicalToNo)
           $ (F.rsubset %~ missingPID3)
           $ (F.rsubset %~ missingPID7)
           $ (F.rsubset %~ missingEducation) r

fixCESCLInt :: ( F.ElemOf rs CESVVoterStatus
               , F.ElemOf rs CESVTurnout)
         => F.Rec (Maybe F.:. F.ElField) rs  -> F.Rec (Maybe F.:. F.ElField) rs
fixCESCLInt = (F.rsubset %~ missingVRegI)
              . (F.rsubset %~ missingVTurnoutI)


fixCESCLText :: ( F.ElemOf rs CESVVoterStatusT
                , F.ElemOf rs CESVTurnoutT)
         => F.Rec (Maybe F.:. F.ElField) rs  -> F.Rec (Maybe F.:. F.ElField) rs
fixCESCLText = (F.rsubset %~ missingVRegT)
               . (F.rsubset %~ missingVTurnoutT)


fixPresVote :: forall rs.(F.ElemOf rs CESPresVote, (F.RDelete CESPresVote rs) F.⊆ rs)
            =>   F.Rec (Maybe F.:. F.ElField) rs  -> F.Rec (Maybe F.:. F.ElField) (FixPresVote rs)
fixPresVote x = F.rcast @(F.RDelete CESPresVote rs) x F.<+> (missingPresVote $ F.rcast x)

fixHouseVote :: forall rs.(F.ElemOf rs CESHouseVote, (F.RDelete CESHouseVote rs) F.⊆ rs)
            =>   F.Rec (Maybe F.:. F.ElField) rs  -> F.Rec (Maybe F.:. F.ElField) (FixHouseVote rs)
fixHouseVote x = F.rcast @(F.RDelete CESHouseVote rs) x F.<+> (missingHouseVote $ F.rcast x)


type TransformAddsR = [BR.Year, GT.CongressionalDistrict, GT.StateFIPS, DT.Age5C, DT.SimpleAgeC, DT.SexC, DT.EducationC, DT.CollegeGradC
                      , DT.Race5C, DT.SimpleRaceC, DT.HispC, DT.EvangelicalC, PartisanId3, PartisanId7, MHouseVoteParty]

transformCES :: (F.ElemOf rs CESCD
                , F.ElemOf rs CESStateFips
                , F.ElemOf rs CESBirthyr
                , F.ElemOf rs CESGender
                , F.ElemOf rs CESEduc
                , F.ElemOf rs CESRace
                , F.ElemOf rs CESHispanic
                , F.ElemOf rs CESPewBornagain
                , F.ElemOf rs CESPid3
                , F.ElemOf rs CESPid7
                , F.ElemOf rs MCESHouseVote
                , F.ElemOf rs CESHouseCand1Party
                , F.ElemOf rs CESHouseCand2Party
                , F.ElemOf rs CESHouseCand3Party
                , F.ElemOf rs CESHouseCand4Party
                )
             => Int -> Bool -> F.Record rs -> F.Record (TransformAddsR V.++ rs)
transformCES yr isGender4 = addCols where
  birthYrToAge x = yr - x
  houseVoteParty :: MT.MaybeData Int -> Text -> Text -> Text -> Text -> MT.MaybeData ET.PartyT
  houseVoteParty mhCand c1P c2P c3P c4P = fmap f mhCand where
    f x = parseHouseVoteParty
      $ case x of
          1 -> c1P
          2 -> c2P
          3 -> c3P
          4 -> c4P
          _ -> "Other"
  intToSex' = if isGender4 then gender4ToSex else intToSex
  addCols = (FT.addOneFromValue @BR.Year yr)
            . (FT.addName @CESCD @GT.CongressionalDistrict)
            . (FT.addName @CESStateFips @GT.StateFIPS)
            . (FT.addOneFromOne @CESBirthyr @DT.Age5C (intToAgeT . birthYrToAge))
            . (FT.addOneFromOne @CESBirthyr @DT.SimpleAgeC (intToSimpleAge . birthYrToAge))
            . (FT.addOneFromOne @CESGender @DT.SexC intToSex')
            . (FT.addOneFromOne @CESEduc @DT.EducationC intToEducation)
            . (FT.addOneFromOne @CESEduc @DT.CollegeGradC intToCollegeGrad)
            . (FT.addOneFromOne @CESRace @DT.Race5C (raceToRace5 . intToRaceT))
            . (FT.addOneFromOne @CESRace @DT.SimpleRaceC (raceToSimpleRace . intToRaceT))
            . (FT.addOneFromOne @CESHispanic @DT.HispC intToHisp)
            . (FT.addOneFromOne @CESPewBornagain @DT.EvangelicalC intToEvangelical)
            . (FT.addOneFromOne @CESPid3 @PartisanId3 parsePartisanIdentity3)
            . (FT.addOneFromOne @CESPid7 @PartisanId7 parsePartisanIdentity7)
            . (FT.addOneFrom @[MCESHouseVote,CESHouseCand1Party,CESHouseCand2Party,CESHouseCand3Party,CESHouseCand4Party] @MHouseVoteParty houseVoteParty)
--            . (FT.addOneFromOne @CESPresVote @PresVoteParty pres2020intToParty)

transformCESCLInt :: (F.ElemOf rs CESVVoterStatus, F.ElemOf rs CESVTurnout)
                  =>  F.Record rs -> F.Record ([VRegistrationC, VTurnoutC] V.++ rs)
transformCESCLInt =   (FT.addOneFromOne @CESVVoterStatus @VRegistrationC cesIntToRegistration)
                      . (FT.addOneFromOne @CESVTurnout @VTurnoutC cesIntToTurnout)

transformCESCLText :: (F.ElemOf rs CESVVoterStatusT, F.ElemOf rs CESVTurnoutT)
                  =>  F.Record rs -> F.Record ([VRegistrationC, VTurnoutC] V.++ rs)
transformCESCLText =   (FT.addOneFromOne @CESVVoterStatusT @VRegistrationC $ catalistRegistrationFromNText 7)
                      . (FT.addOneFromOne @CESVTurnoutT @VTurnoutC $ catalistTurnoutFromNText 7)

transformCESTargetSmart :: (F.ElemOf rs CESVVoterStatus, F.ElemOf rs CESVTurnout)
                        =>  F.Record rs -> F.Record ([VRegistrationC, VTurnoutC] V.++ rs)
transformCESTargetSmart = (FT.addOneFromOne @CESVVoterStatus @VRegistrationC tsIntToRegistration)
                          . (FT.addOneFromOne @CESVTurnout @VTurnoutC tsIntToTurnout)

type MCESHouseVote = "HouseVoteInt" F.:-> MT.MaybeData Int
type MCESPresVote = "PresVoteInt" F.:-> MT.MaybeData Int

missingPreWeight :: F.Rec (Maybe :. F.ElField) '[CESPreWeight] -> F.Rec (Maybe :. F.ElField) '[CESPreWeight]
missingPreWeight = FM.fromMaybeMono 0
missingPostWeight :: F.Rec (Maybe :. F.ElField) '[CESPostWeight] -> F.Rec (Maybe :. F.ElField) '[CESPostWeight]
missingPostWeight = FM.fromMaybeMono 0
--missingRegWeight :: F.Rec (Maybe :. F.ElField) '[CESRegisteredWeight] -> F.Rec (Maybe :. F.ElField) '[CESRegisteredWeight]
--missingRegWeight = FM.fromMaybeMono 0
missingHispanicToNo :: F.Rec (Maybe :. F.ElField) '[CESHispanic] -> F.Rec (Maybe :. F.ElField) '[CESHispanic]
missingHispanicToNo = FM.fromMaybeMono 2
missingPID3 :: F.Rec (Maybe :. F.ElField) '[CESPid3] -> F.Rec (Maybe :. F.ElField) '[CESPid3]
missingPID3 = FM.fromMaybeMono 6
missingPID7 :: F.Rec (Maybe :. F.ElField) '[CESPid7] -> F.Rec (Maybe :. F.ElField) '[CESPid7]
missingPID7 = FM.fromMaybeMono 9
missingEducation :: F.Rec (Maybe :. F.ElField) '[CESEduc] -> F.Rec (Maybe :. F.ElField) '[CESEduc]
missingEducation = FM.fromMaybeMono 5
missingVRegI :: F.Rec (Maybe :. F.ElField) '[CESVVoterStatus] -> F.Rec (Maybe :. F.ElField) '[CESVVoterStatus]
missingVRegI = FM.fromMaybeMono 10
missingVTurnoutI :: F.Rec (Maybe :. F.ElField) '[CESVTurnout] -> F.Rec (Maybe :. F.ElField) '[CESVTurnout]
missingVTurnoutI = FM.fromMaybeMono 10
missingVRegT :: F.Rec (Maybe :. F.ElField) '[CESVVoterStatusT] -> F.Rec (Maybe :. F.ElField) '[CESVVoterStatusT]
missingVRegT = FM.fromMaybeMono "missing"
missingVTurnoutT :: F.Rec (Maybe :. F.ElField) '[CESVTurnoutT] -> F.Rec (Maybe :. F.ElField) '[CESVTurnoutT]
missingVTurnoutT = FM.fromMaybeMono "missing"
missingHouseVote :: F.Rec (Maybe :. F.ElField) '[CESHouseVote] -> F.Rec (Maybe :. F.ElField) '[MCESHouseVote]
missingHouseVote = FM.maybeMono (MT.MaybeData Nothing) (MT.MaybeData . Just)
missingPresVote :: F.Rec (Maybe :. F.ElField) '[CESPresVote] -> F.Rec (Maybe :. F.ElField) '[MCESPresVote]
missingPresVote = FM.maybeMono (MT.MaybeData Nothing) (MT.MaybeData . Just)
missingEvangelicalToNo :: F.Rec (Maybe :. F.ElField) '[CESPewBornagain] -> F.Rec (Maybe :. F.ElField) '[CESPewBornagain]
missingEvangelicalToNo = FM.fromMaybeMono 2

ccesDataLoader :: (K.KnitEffects r, BR.CacheEffects r) => K.Sem r (K.ActionWithCacheTime r (F.FrameRec CES_MRP))
ccesDataLoader = K.wrapPrefix "ccesDataLoader" $ do
  K.logLE K.Info "Loading/Building CES data"
  BR.cachedMaybeFrameLoader @(F.RecordColumns CES.CES) @CES_MRP_Raw -- @CES_MRP
    (BR.LocalData $ toText ces2020C_CSV)
    (Just cESParser)
    Nothing
    fixCESRow
    transformCESRow
    Nothing
    "cces_2006_2020.bin"

type CES_MRP_Raw = '[ CESYear
                     , CESCaseId
                     , CESWeight
                     , CESWeightCumulative
                     , CESSt
                     , CESDistUp
                     , CESGender
                     , CESAge
                     , CESEduc
                     , CESRace
                     , CESHispanic -- 1 for yes, 2 for no.  Missing is no. hispanic race + no = hispanic.  any race + yes = hispanic (?)
--                     , CESPewBornagain
                     , CESPid3
                     , CESPid7
                     , CESPid3Leaner
                     , CESVvRegstatus
                     , CESVvTurnoutGvm
                     , CESVotedRepParty
                     , CESVotedPres08
                     , CESVotedPres12
                     , CESVotedPres16
                     , CESVotedPres20
                     ]

type CES_MRP = '[ BR.Year
                 , CESCaseId
                 , CESWeight
                 , CESWeightCumulative
                 , BR.StateAbbreviation
                 , BR.CongressionalDistrict
                 , DT.SexC
                 , DT.Age5C
                 , DT.SimpleAgeC
                 , DT.EducationC
                 , DT.CollegeGradC
                 , DT.Race5C
                 , DT.HispC
                 , DT.SimpleRaceC
--                 , DT.EvangelicalC
                 , PartisanId3
                 , PartisanId7
                 , PartisanIdLeaner
                 , Registration
                 , Turnout
                 , HouseVoteParty
                 , Pres2008VoteParty
                 , Pres2012VoteParty
                 , Pres2016VoteParty
                 , Pres2020VoteParty
                 ]


-- can't do toEnum here because we have Female first
intToSex :: Int -> DT.Sex
intToSex n = case n of
  1 -> DT.Male
  2 -> DT.Female
  _ -> error "Int other 1 or 2 in \"intToSex\""

-- NB: THis needs fixing but not until ACS also has multi-category gender.
gender4ToSex :: Int -> DT.Sex
gender4ToSex n | n == 1 = DT.Male
               | n == 2 = DT.Female
               | otherwise = DT.Female


intToEducation :: Int -> DT.Education
intToEducation 1 = DT.L9
intToEducation 2 = DT.L12
intToEducation 3 = DT.HS
intToEducation 4 = DT.AS
intToEducation 5 = DT.BA
intToEducation 6 = DT.AD
intToEducation _ = DT.AD -- higher numbers would mean all of these are wrong but more likely to mean higher degree

intToCollegeGrad :: Int -> DT.CollegeGrad
intToCollegeGrad n = if n >= 4 then DT.Grad else DT.NonGrad

data RaceT = White | Black | Hispanic | Asian | NativeAmerican | Mixed | Other | MiddleEastern deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor RaceT = V.Vector
instance Flat.Flat RaceT

intToRaceT :: Int -> RaceT
intToRaceT = fromMaybe Other . Relude.safeToEnum . minus1

type Race = "Race" F.:-> RaceT
instance FV.ToVLDataValue (F.ElField Race) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)

raceToSimpleRace :: RaceT -> DT.SimpleRace
raceToSimpleRace White = DT.White
raceToSimpleRace _ = DT.NonWhite


raceToRace5 :: RaceT -> DT.Race5
raceToRace5 White = DT.R5_WhiteNonHispanic
raceToRace5 Black = DT.R5_Black
raceToRace5 Hispanic = DT.R5_Hispanic
raceToRace5 Asian = DT.R5_Asian
raceToRace5 _ = DT.R5_Other

intToHisp :: Int -> DT.Hisp
intToHisp n
  | n == 1 = DT.Hispanic
  | otherwise = DT.NonHispanic


intToAgeT :: Real a => a -> DT.Age5
intToAgeT x
  | x < 25 = DT.A5_18To24
  | x < 35 = DT.A5_25To34
  | x < 45 = DT.A5_35To44
  | x < 65 = DT.A5_45To64
  | otherwise = DT.A5_65AndOver

intToSimpleAge :: Int -> DT.SimpleAge
intToSimpleAge n = if n < 45 then DT.Under else DT.EqualOrOver

data RegistrationT = R_Active
                   | R_NoRecord
                   | R_Unregistered
                   | R_Dropped
                   | R_Inactive
                   | R_Multiple
                   | R_Missing deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor RegistrationT = V.Vector
instance Flat.Flat RegistrationT


parseRegistration :: T.Text -> RegistrationT
parseRegistration "Active" = R_Active
parseRegistration "No Record Of Registration" = R_NoRecord
parseRegistration "Unregistered" = R_Unregistered
parseRegistration "Dropped" = R_Dropped
parseRegistration "Inactive" = R_Inactive
parseRegistration "Multiple Appearances" = R_Multiple
parseRegistration _ = R_Missing

type Registration = "Registration" F.:-> RegistrationT
instance FV.ToVLDataValue (F.ElField Registration) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)

data RegPartyT = RP_NoRecord
               | RP_Unknown
               | RP_Democratic
               | RP_Republican
               | RP_Green
               | RP_Independent
               | RP_Libertarian
               | RP_Other deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor RegPartyT = V.Vector
instance Flat.Flat RegPartyT

parseRegParty :: T.Text -> RegPartyT
parseRegParty "No Record Of Party Registration" = RP_NoRecord
parseRegParty "Unknown" = RP_Unknown
parseRegParty "Democratic" = RP_Democratic
parseRegParty "Republican" = RP_Republican
parseRegParty "Green" = RP_Green
parseRegParty "Independent" = RP_Independent
parseRegParty "Libertarian" = RP_Libertarian
parseRegParty _ = RP_Other

type RegParty = "RegParty" F.:-> RegPartyT
instance FV.ToVLDataValue (F.ElField RegParty) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)

data TurnoutT = T_Voted
              | T_NoRecord
              | T_NoFile
              | T_Missing deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor TurnoutT = V.Vector
instance Flat.Flat TurnoutT

parseTurnout :: T.Text -> TurnoutT
parseTurnout "Voted" = T_Voted
parseTurnout "No Record Of Voting" = T_NoRecord
parseTurnout "No Voter File" = T_NoFile
parseTurnout _ = T_Missing

type Turnout = "Turnout" F.:-> TurnoutT
instance FV.ToVLDataValue (F.ElField Turnout) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)

data PartisanIdentity3 = PI3_Democrat
                       | PI3_Republican
                       | PI3_Independent
                       | PI3_Other
                       | PI3_NotSure
                       | PI3_Missing deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor PartisanIdentity3 = V.Vector
instance Flat.Flat PartisanIdentity3

parsePartisanIdentity3 :: Int -> PartisanIdentity3
parsePartisanIdentity3 = fromMaybe PI3_Missing . Relude.safeToEnum . minus1 . min 6

type PartisanId3 = "PartisanId3" F.:-> PartisanIdentity3
instance FV.ToVLDataValue (F.ElField PartisanId3) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)


data PartisanIdentity7 = PI7_StrongDem
                       | PI7_WeakDem
                       | PI7_LeanDem
                       | PI7_Independent
                       | PI7_LeanRep
                       | PI7_WeakRep
                       | PI7_StrongRep
                       | PI7_NotSure
                       | PI7_Missing deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor PartisanIdentity7 = V.Vector
instance Flat.Flat PartisanIdentity7

parsePartisanIdentity7 :: Int -> PartisanIdentity7
parsePartisanIdentity7 = fromMaybe PI7_Missing . Relude.safeToEnum . minus1 . min 9

type PartisanId7 = "PartisanId7" F.:-> PartisanIdentity7
instance FV.ToVLDataValue (F.ElField PartisanId7) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)


data PartisanIdentityLeaner = PIL_Democrat
                            | PIL_Republican
                            | PIL_Independent
                            | PIL_NotSure
                            | PIL_Missing deriving stock (Show, Enum, Bounded, Eq, Ord, Generic)
type instance FI.VectorFor PartisanIdentityLeaner = V.Vector
instance Flat.Flat PartisanIdentityLeaner

parsePartisanIdentityLeaner :: Int -> PartisanIdentityLeaner
parsePartisanIdentityLeaner = fromMaybe PIL_Missing . Relude.safeToEnum . minus1 . min 5

type PartisanIdLeaner = "PartisanIdLeaner" F.:-> PartisanIdentityLeaner
instance FV.ToVLDataValue (F.ElField PartisanIdLeaner) where
  toVLDataValue x = (toText $ V.getLabel x, GV.Str $ show $ V.getField x)

parseHouseVoteParty :: T.Text -> ET.PartyT
parseHouseVoteParty "Democratic" = ET.Democratic
parseHouseVoteParty "Republican" = ET.Republican
parseHouseVoteParty _ = ET.Other

type HouseVoteParty = "HouseVoteParty" F.:-> ET.PartyT

parsePres2020VoteParty :: T.Text -> ET.PartyT
parsePres2020VoteParty "Joe Biden" = ET.Democratic
parsePres2020VoteParty "Donald Trump" = ET.Republican
parsePres2020VoteParty _ = ET.Other

parsePres2016VoteParty :: T.Text -> ET.PartyT
parsePres2016VoteParty "Hilary Clinton" = ET.Democratic
parsePres2016VoteParty "Donald Trump" = ET.Republican
parsePres2016VoteParty _ = ET.Other

parsePres2012VoteParty :: T.Text -> ET.PartyT
parsePres2012VoteParty "Barack Obama" = ET.Democratic
parsePres2012VoteParty "Mitt Romney" = ET.Republican
parsePres2012VoteParty _ = ET.Other

parsePres2008VoteParty :: T.Text -> ET.PartyT
parsePres2008VoteParty t = if T.isInfixOf "Barack Obama" t
                           then ET.Democratic
                           else if T.isInfixOf "John McCain" t
                                then ET.Republican
                                     else ET.Other

type PresVoteParty = "PresVoteParty" F.:-> ET.PartyT
type Pres2016VoteParty = "Pres2016VoteParty" F.:-> ET.PartyT
type Pres2012VoteParty = "Pres2012VoteParty" F.:-> ET.PartyT
type Pres2008VoteParty = "Pres2008VoteParty" F.:-> ET.PartyT
type Pres2020VoteParty = "Pres2020VoteParty" F.:-> ET.PartyT


-- to use in maybeRecsToFrame
fixCESRow :: F.Rec (Maybe F.:. F.ElField) CES_MRP_Raw -> F.Rec (Maybe F.:. F.ElField) CES_MRP_Raw
fixCESRow r = (F.rsubset %~ missingHispanicToNo)
--               $ (F.rsubset %~ missingEvangelicalToNo)
               $ (F.rsubset %~ missingPID3)
               $ (F.rsubset %~ missingPID7)
               $ (F.rsubset %~ missingPIDLeaner)
               $ (F.rsubset %~ missingEducation)
               r where
--  missingHispanicToNo :: F.Rec (Maybe :. F.ElField) '[CESHispanic] -> F.Rec (Maybe :. F.ElField) '[CESHispanic]
--  missingHispanicToNo = FM.fromMaybeMono 2
--  missingPID3 :: F.Rec (Maybe :. F.ElField) '[CESPid3] -> F.Rec (Maybe :. F.ElField) '[CESPid3]
--  missingPID3 = FM.fromMaybeMono 6
--  missingPID7 :: F.Rec (Maybe :. F.ElField) '[CESPid7] -> F.Rec (Maybe :. F.ElField) '[CESPid7]
--  missingPID7 = FM.fromMaybeMono 9
  missingPIDLeaner :: F.Rec (Maybe :. F.ElField) '[CESPid3Leaner] -> F.Rec (Maybe :. F.ElField) '[CESPid3Leaner]
  missingPIDLeaner = FM.fromMaybeMono 5
--  missingEducation :: F.Rec (Maybe :. F.ElField) '[CESEduc] -> F.Rec (Maybe :. F.ElField) '[CESEduc]
--  missingEducation = FM.fromMaybeMono 5

intToEvangelical :: Int -> DT.Evangelical
intToEvangelical 1 = DT.Evangelical
intToEvangelical _ = DT.NonEvangelical

--textToInt :: T.Text -> Int
--textToInt = either (const 0) fst . Text.Read.decimal

-- fmap over Frame after load and throwing out bad rows

transformCESRow :: F.Record CES_MRP_Raw -> F.Record CES_MRP
transformCESRow = F.rcast . addCols where
  addCols = (FT.addName  @CESYear @BR.Year)
            . (FT.addName @CESSt @BR.StateAbbreviation)
            . (FT.addName @CESDistUp @BR.CongressionalDistrict)
            . (FT.addOneFromOne @CESGender @DT.SexC intToSex)
            . (FT.addOneFromOne @CESEduc @DT.EducationC intToEducation)
            . (FT.addOneFromOne @CESEduc @DT.CollegeGradC intToCollegeGrad)
            . (FT.addOneFromOne @CESRace @DT.Race5C (raceToRace5 . intToRaceT))
            . (FT.addOneFromOne @CESRace @DT.SimpleRaceC (raceToSimpleRace . intToRaceT))
            . (FT.addOneFromOne @CESHispanic @DT.HispC intToHisp)
            . (FT.addOneFromOne @CESAge @DT.Age5C intToAgeT)
            . (FT.addOneFromOne @CESAge @DT.SimpleAgeC intToSimpleAge)
--            . (FT.addOneFromOne @CESPewBornagain @DT.EvangelicalC intToEvangelical)
            . (FT.addOneFromOne @CESVvRegstatus @Registration parseRegistration)
            . (FT.addOneFromOne @CESVvTurnoutGvm @Turnout parseTurnout)
            . (FT.addOneFromOne @CESVotedRepParty @HouseVoteParty parseHouseVoteParty)
            . (FT.addOneFromOne @CESVotedPres08 @Pres2008VoteParty parsePres2008VoteParty)
            . (FT.addOneFromOne @CESVotedPres12 @Pres2012VoteParty parsePres2012VoteParty)
            . (FT.addOneFromOne @CESVotedPres16 @Pres2016VoteParty parsePres2016VoteParty)
            . (FT.addOneFromOne @CESVotedPres20 @Pres2020VoteParty parsePres2016VoteParty)
            . (FT.addOneFromOne @CESPid3 @PartisanId3 parsePartisanIdentity3)
            . (FT.addOneFromOne @CESPid7 @PartisanId7 parsePartisanIdentity7)
            . (FT.addOneFromOne @CESPid3Leaner @PartisanIdLeaner parsePartisanIdentityLeaner)



-- map reduce folds for counting

-- some keys for aggregation
type ByCESPredictors = '[BR.StateAbbreviation, DT.SimpleAgeC, DT.SexC, DT.CollegeGradC, DT.SimpleRaceC]


--
countDVotesF
  :: forall vc cs
  . (Ord (F.Record cs)
    , FI.RecVec (cs V.++ BR.CountCols)
    , F.ElemOf CES_MRP vc
    , V.KnownField vc
    , V.Snd vc ~ ET.PartyT
    )
  => (F.Record CES_MRP -> F.Record cs)
  -> Int
  -> FMR.Fold (F.Record CES_MRP) (F.FrameRec (cs V.++ BR.CountCols))
countDVotesF getKeys y =
  BR.weightedCountFold
  getKeys
  (F.rcast @[vc, CESWeightCumulative])
  (\r ->
     (F.rgetField @BR.Year r == y)
     && (F.rgetField @vc r `elem` [ET.Republican, ET.Democratic])
  )
  ((== ET.Democratic) . F.rgetField @vc)
  (F.rgetField @CESWeightCumulative)

{-
countDemHouseVotesF
  :: forall cs
  . (Ord (F.Record cs)
    , FI.RecVec (cs V.++ BR.CountCols)
    )
  => Int
  -> FMR.Fold
  (F.Record CES_MRP)
  (F.FrameRec (cs V.++ BR.CountCols))
countDemHouseVotesF = countDVotesF @HouseVoteParty

countDemPres2008VotesF
  :: forall cs
  . (Ord (F.Record cs)
    , FI.RecVec (cs V.++ BR.CountCols)
    )
  => FMR.Fold
  (F.Record CES_MRP)
  (F.FrameRec (cs V.++ BR.CountCols))
countDemPres2008VotesF = countDVotesF @Pres2008VoteParty 2008

countDemPres2012VotesF
  :: forall cs
  . (Ord (F.Record cs)
    , FI.RecVec (cs V.++ BR.CountCols)
    , cs F.⊆ CES_MRP
    , cs F.⊆ ('[BR.StateAbbreviation] V.++ cs V.++ CES_MRP)
    , F.ElemOf (cs V.++ CES_MRP) Pres2012VoteParty
    , F.ElemOf (cs V.++ CES_MRP) CESWeightCumulative
    )
  => FMR.Fold
  (F.Record CES_MRP)
  (F.FrameRec ('[BR.StateAbbreviation] V.++ cs V.++ BR.CountCols))
countDemPres2012VotesF =
  BR.weightedCountFold @('[BR.StateAbbreviation] V.++ cs) @CES_MRP
    @'[Pres2012VoteParty, CESWeightCumulative]
    (\r ->
      (F.rgetField @BR.Year r == 2012)
        && (      F.rgetField @Pres2012VoteParty r
           `elem` [ET.Republican, ET.Democratic]
           )
    )
    ((== ET.Democratic) . F.rgetField @Pres2012VoteParty)
    (F.rgetField @CESWeightCumulative)

countDemPres2016VotesF
  :: forall cs
  . (Ord (F.Record cs)
    , FI.RecVec (cs V.++ BR.CountCols)
    , cs F.⊆ CES_MRP
    , cs F.⊆ ('[BR.StateAbbreviation] V.++ cs V.++ CES_MRP)
    , F.ElemOf (cs V.++ CES_MRP) Pres2016VoteParty
    , F.ElemOf (cs V.++ CES_MRP) CESWeightCumulative
    )
  => FMR.Fold
  (F.Record CES_MRP)
  (F.FrameRec ('[BR.StateAbbreviation] V.++ cs V.++ BR.CountCols))
countDemPres2016VotesF =
  BR.weightedCountFold @('[BR.StateAbbreviation] V.++ cs) @CES_MRP
    @'[Pres2016VoteParty, CESWeightCumulative]
    (\r ->
      (F.rgetField @BR.Year r == 2016)
        && (      F.rgetField @Pres2016VoteParty r
           `elem` [ET.Republican, ET.Democratic]
           )
    )
    ((== ET.Democratic) . F.rgetField @Pres2016VoteParty)
    (F.rgetField @CESWeightCumulative)
-}
