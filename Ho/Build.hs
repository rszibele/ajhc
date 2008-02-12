module Ho.Build (
    module Ho.Type,
    dumpHoFile,
    findModule,
    doDependency,
    buildLibrary
    ) where


import Codec.Compression.GZip
import Control.Monad.Identity
import Data.Binary
import Data.Monoid
import Data.IORef
import Data.Tree
import Data.List hiding(union)
import Maybe
import Monad
import Text.Printf
import Prelude hiding(print,putStrLn)
import System.IO hiding(print,putStrLn)
import System.Posix.Files
import qualified Data.ByteString.Lazy as L
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Text.PrettyPrint.HughesPJ as PPrint

import StringTable.Atom
import PackedString(packString)
import CharIO
import DataConstructors
import Directory
import Doc.DocLike
import Doc.PPrint
import Doc.Pretty
import E.E
import E.Rules
import E.Show
import E.Traverse(emapE)
import E.TypeCheck()
import FrontEnd.Class
import FrontEnd.HsParser
import FrontEnd.Infix
import FrontEnd.ParseMonad
import FrontEnd.Syn.Options
import FrontEnd.Unlit
import FrontEnd.Warning
import FrontEnd.SrcLoc
import Ho.Binary()
import Ho.Library
import Ho.Type
import HsSyn
import Options
import Support.CFF
import Util.FilterInput
import Util.Gen hiding(putErrLn,putErr,putErrDie)
import Util.SetLike
import Version.Version(versionString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified FlagDump as FD
import qualified FlagOpts as FO
import qualified Util.Graph as G
import qualified Support.MD5 as MD5
import qualified UTF8


--
-- Ho File Format
--
-- ho files are standard CFF format files (PNG-like) as described in the Support.CFF modules.
--
-- the CFF magic for the files is the string "JHC"
--
-- JHDR - header info, contains a list of modules contained and dependencies that need to be checked to read the file
-- LIBR - only present if this is a library, contains library metainfo
-- IDEP - immutable import information
-- RDRT - redirect to another file for systems without symlinks
-- DEFS - definitions and exports for modules, all that is needed for name resolution
-- TCIN - type checking information
-- CORE - compiled core and associated data
-- GRIN - compiled grin code
--
--

cff_magic = chunkType "JHC"
cff_rdrt  = chunkType "RDRT"
cff_jhdr  = chunkType "JHDR"
cff_core  = chunkType "CORE"
cff_defs  = chunkType "DEFS"
cff_idep  = chunkType "IDEP"


shortenPath :: String -> IO String
shortenPath x@('/':_) = do
    cd <- getCurrentDirectory
    pwd <- lookupEnv "PWD"
    h <- lookupEnv "HOME"
    --print (x,cd,h)
    let f d = d >>= \d -> getPrefix d x >>= \ ('/':rest) -> return rest
    return $ fromJust $ f (return cd) `mplus` f pwd `mplus` liftM ("~/" ++) (f h) `mplus` return x
shortenPath x = return x


type SourceHash = MD5.Hash
type HoHash     = MD5.Hash

instance DocLike d => PPrint d MD5.Hash where
    pprintPrec _ h = tshow h


findFirstFile :: String -> [(FilePath,a)] -> IO (LBS.ByteString,FilePath,a)
findFirstFile err [] = FrontEnd.Warning.err "missing-dep" ("Module not found: " ++ err) >> fail ("Module not found: " ++ err) -- return (error "findFirstFile not found","",undefined)
findFirstFile err ((x,a):xs) = flip catch (\e ->   findFirstFile err xs) $ do
    bs <- LBS.readFile x
    return (bs,x,a)


data ModDone
    = ModNotFound
    | ModLibrary String
    | Found SourceCode

data Done = Done {
    knownSourceMap :: Map.Map SourceHash (Module,[Module]),
    hosEncountered :: Map.Map HoHash     (FilePath,HoHeader,Ho),
    modEncountered :: Map.Map Module     ModDone
    }
    {-! derive: Monoid, update !-}

fileOrModule f = case reverse f of
                   ('s':'h':'.':_)     -> Right f
                   ('s':'h':'l':'.':_) -> Right f
                   _                   -> Left $ Module f

{-# NOINLINE doDependency #-}
doDependency :: [String] -> IO ()
doDependency as = do
    done_ref <- newIORef mempty;
    let f (Right f) = fetchSource done_ref [f] Nothing >> return ()
        f (Left m) = resolveDeps done_ref m
    mapM_ (f . fileOrModule) as
    sm <- knownSourceMap `fmap` readIORef done_ref
    mapM_ print $ melems sm

replaceSuffix suffix fp = reverse (dropWhile ('.' /=) (reverse fp)) ++ suffix

findHoFile :: IORef Done -> FilePath -> Maybe Module -> SourceHash -> IO (Maybe FilePath)
findHoFile done_ref fp _ sh = do
    done <- readIORef done_ref
    if sh `Map.member` knownSourceMap done then return Nothing else do
    let honame = replaceSuffix "ho" fp
    onErr (return Nothing) (readHoFile honame) $ \ (hoh,hidep,ho) -> do
        case hohHash hoh `Map.lookup` hosEncountered done of
            Just (fn,_,_a) -> return (Just fn)
            Nothing -> do
                honame <- shortenPath honame
                modifyIORef done_ref (knownSourceMap_u $ mappend (hoIDeps hidep))
                modifyIORef done_ref (hosEncountered_u $ Map.insert (hohHash hoh) (honame,hoh,ho))
                return (Just honame)



onErr :: IO a -> IO b -> (b -> IO a) -> IO a
onErr err good cont = catch (good >>= \c -> return (cont c)) (\_ -> return err) >>= id

fetchSource :: IORef Done -> [FilePath] -> Maybe Module -> IO Module
fetchSource _ [] _ = fail "No files to load"
fetchSource done_ref fs mm = do
    let mod = maybe (head fs) show mm
        killMod = case mm of
            Nothing -> fail $ "Could not load file: " ++ show fs
            Just m -> modifyIORef done_ref (modEncountered_u $ Map.insert m ModNotFound) >> return m
    onErr killMod (findFirstFile mod [ (f,undefined) | f <- fs]) $ \ (lbs,fn,_) -> do
    let hash = MD5.md5lazy lbs
    mho <- findHoFile done_ref fn mm hash
    done <- readIORef done_ref
    (mod,m,ds) <- case mlookup hash (knownSourceMap done) of
        Just (m,ds) -> do return (Left lbs,m,ds)
        Nothing -> do
            hmod <- parseHsSource fn lbs
            let m = hsModuleName hmod
                ds = hsModuleRequires hmod
            writeIORef done_ref (knownSourceMap_u (Map.insert hash (m,ds)) done)
            return (Right hmod,m,ds)
    case mm of
        Just m' | m /= m' -> do
            putErrLn $ "Skipping file" <+> fn <+> "because it's module declaration of" <+> show m <+> "does not equal the expected" <+> show m'
            killMod
        _ -> do
            fn' <- shortenPath fn
            let sc (Right mod) = SourceParsed hash ds mod fn
                sc (Left lbs) = SourceRaw hash ds m lbs fn
            modifyIORef done_ref (modEncountered_u $ Map.insert m (Found (sc mod)))
            case mho of
                Nothing -> putVerboseLn $ printf "%-23s [%s]" (show m) fn'
                Just ho -> putVerboseLn $ printf "%-23s [%s] <%s>" (show m) fn' ho
            mapM_ (resolveDeps done_ref) ds
            return m

resolveDeps :: IORef Done -> Module -> IO ()
resolveDeps done_ref m = do
    done <- readIORef done_ref
    if isJust $ m `mlookup` modEncountered done then return () else do
    fetchSource done_ref (map fst $ searchPaths (show m)) (Just m)
    return ()


data SourceCode
    = SourceParsed { sourceHash :: SourceHash, sourceDeps :: [Module], sourceModule :: HsModule, sourceFP :: FilePath }
    | SourceRaw    { sourceHash :: SourceHash, sourceDeps :: [Module], sourceModName :: Module, sourceLBS :: LBS.ByteString, sourceFP :: FilePath }


sourceIdent SourceParsed { sourceModule = m } = show $ hsModuleName m
sourceIdent SourceRaw { sourceModName = fp } = show fp

data CompUnit
    = CompLibrary String
    | CompHo      HoHeader Ho
    | CompSources [SourceCode]

type CompUnitGraph = [(HoHash,([HoHash],CompUnit))]

showCUnit (hash,(deps,cu)) = printf "%s : %s" (show hash) (show deps)  ++ "\n" ++ f cu where
    f (CompLibrary s) = s
    f (CompHo _ _) = "ho"
    f (CompSources ss) = show $ map sourceIdent ss


toCompUnitGraph :: Done -> [Module] -> IO CompUnitGraph
toCompUnitGraph done roots = do
    let fs m = maybe (error $ "can't find deps for: " ++ show m) snd (Map.lookup m (knownSourceMap done))
        gr = G.newGraph  [ ((m,sourceHash sc),fs (sourceHash sc)) | (m,Found sc) <- Map.toList (modEncountered done)] (fst . fst) snd
        gr' = G.sccGroups gr
        phomap = Map.fromListWith (++) (concat [  [ (m,[hh]) | (m,_) <- hohDepends hoh ] | (hh,(_,hoh,_)) <- Map.toList (hosEncountered done)])
        sources = Map.fromList [ (m,sourceHash sc) | (m,Found sc) <- Map.toList (modEncountered done)]
    when (dump FD.SccModules) $ do
        putErrLn $ drawForest (map (fmap (show . fst . fst)) (G.dff gr))

    cug_ref <- newIORef []
    hom_ref <- newIORef (Map.map ((,) False) $ hosEncountered done)
    ms <- forM gr' $ \ns -> do
            r <- newIORef (Left ns)
            return [ (m,r) | ((m,_),_) <- ns ]
    let mods = Map.fromList (concat ms)
    let f m = do
            rr <- Map.lookup m mods  >>= readIORef
            case rr of
                Right hh -> return hh
                Left ns -> g ns
        g ms@(((m,_),ds):_) = do
            let amods = map (fst . fst) ms
            pm (join (Map.lookup m phomap)) $ do
                let deps = Set.toList $ Set.fromList (concat $ snds ms) `Set.difference` (Set.fromList (map (fst . fst) ms))
                deps' <- snub `fmap` mapM f deps
                let mhash = MD5.md5String (concatMap (show . fst) ms ++ show deps')
                Map.lookup m mods >>= flip writeIORef (Right mhash)
                let cunit = CompSources $ map fs amods
                modifyIORef cug_ref ((mhash,(deps',cunit)):)
                return mhash
        pm :: [HoHash] -> IO HoHash -> IO HoHash
        pm [] els = els
        pm (h:hs) els = do catch (hvalid h) (\_ -> pm hs els)
        hvalid h = do
            ll <- Map.lookup h `fmap` readIORef hom_ref
            case ll of
                Nothing -> fail "Don't know anything about this hash"
                Just (True,_) -> return h
                Just (False,af@(fp,hoh,ho)) -> do
                    good <- catch ( mapM_ cdep (hohDepends hoh) >> mapM_ hvalid (hohModDepends hoh) >> return True) (\_ -> return False)
                    if good then do
                        putVerboseLn $ printf "Fresh: <%s>" fp
                        modifyIORef cug_ref ((h,(hohModDepends hoh,CompHo hoh ho)):)
                        modifyIORef hom_ref (Map.insert h (True,af))
                        return h
                     else do
                        putVerboseLn $ printf "Stale: <%s>" fp
                        modifyIORef hom_ref (Map.delete h)
                        fail "don't know this file"
        cdep (mod,hash) = case Map.lookup mod sources of
            Just hash' | hash == hash' -> return ()
            _ -> fail "Can't verify module up to date"
        fs m = case Map.lookup m (modEncountered done) of
            Just (Found sc) -> sc
            _ -> error $ "fs: " ++ show m
    mapM_ f roots
    readIORef cug_ref


findModule :: [Either Module String]                                -- ^ Either a module or filename to find
              -> (CollectedHo -> Ho -> IO CollectedHo)              -- ^ Process initial ho loaded from file
              -> (CollectedHo -> [HsModule] -> IO (CollectedHo,Ho)) -- ^ Process set of mutually recursive modules to produce final Ho
              -> IO (CollectedHo,[(Module,MD5.Hash)],Ho)            -- ^ (Final accumulated ho,just the ho read to satisfy this command)
findModule need ifunc func  = do
    done_ref <- newIORef mempty

    unless (null $ optHls options) $ putVerboseLn $ "Loading libraries:" <+> show (optHls options)
    forM_ (optHls options) $ \l -> do
        (n',fn) <- findLibrary l
        (hoh,_,ho) <- catch (readHoFile fn) $ \_ ->
            --putErrLn $ "Error loading library file: " ++ fn
            fail $ "Error loading library file: " ++ fn
        putVerboseLn $ printf "%-15s <%s>" n' fn
        modifyIORef done_ref (hosEncountered_u $ Map.insert (hohHash hoh) (n',hoh,ho))
        modifyIORef done_ref (modEncountered_u $ Map.union (Map.fromList [ (m,ModLibrary n') | (m,_) <- hohDepends hoh]))
    ms1 <- forM (rights need) $ \fn -> do
        fetchSource done_ref [fn] Nothing
    forM_ (lefts need) $ resolveDeps done_ref
    processIOErrors

    let roots = ms1 ++ lefts need

    done <- readIORef done_ref
    cug <- toCompUnitGraph done roots
--    mapM_ (putStrLn . showCUnit) cug


    let f ho libHo [] = processIOErrors >> return (ho,mempty,libHo)
        f ho libHo ((hh,hdep,sc):scs) = do
            modules <- forM sc $ \x -> case x of
                SourceParsed { sourceHash = h,sourceModule = mod } -> return (h,mod)
                SourceRaw { sourceHash = h,sourceLBS = lbs, sourceFP = fp } -> parseHsSource fp lbs >>= return . (,) h
            (cho',newHo) <- func ho (snds modules)
            let hoh = HoHeader {
                                 hohDepends    = [ (hsModuleName mod,h) | (h,mod) <- modules],
                                 hohModDepends = hdep,
                                 hohHash = hh,
                                 hohMetaInfo   = []
                               }
                idep = HoIDeps $ Map.fromList [ (h,(hsModuleName mod,hsModuleRequires mod)) | (h,mod) <- modules]
            recordHoFile newHo idep (map (replaceSuffix "ho" . sourceFP) sc) hoh
            f (cho' `mappend` mempty { choFiles = Map.fromList $ hohDepends hoh, choModules = mprovides hoh }) (libHo `mappend` newHo)  scs
        mprovides hoh = Map.fromList [ (x,hohHash hoh) | (x,_) <- hohDepends hoh]

    let sccm = G.sccGroups $ G.newGraph cug fst (fst . snd)
    let readHo = mconcat [ ho | [(_,(_,CompHo _ ho))] <- sccm ]
    cho <- ifunc mempty (mempty { hoBuild = mempty { hoDataTable = dataTablePrims } } `mappend` readHo)
    f cho mempty [ (hh,hdep,ss) | [(hh,(hdep,CompSources ss))] <- sccm ]


-- Read in a Ho file.

readHoFile :: FilePath -> IO (HoHeader,HoIDeps,Ho)
readHoFile fn = do
    bs <- BS.readFile fn
    (ct,mp) <- bsCFF bs
    True <- return $ ct == cff_magic
    let fc ct = case lookup ct mp of
            Nothing -> error $ "No chunk '" ++ show ct ++ "' found in file " ++ fn
            Just x -> decode . decompress $ L.fromChunks [x]
    return (fc cff_jhdr,fc cff_idep,mempty { hoExp = fc cff_defs, hoBuild = fc cff_core})


recordHoFile ::
    Ho               -- ^ File to record
    -> HoIDeps
    -> [FilePath]    -- ^ files to write to
    -> HoHeader      -- ^ file header
    -> IO ()
recordHoFile ho idep fs header = do
    if optNoWriteHo options then do
        wdump FD.Progress $ do
            fs' <- mapM shortenPath fs
            putErrLn $ "Skipping Writing Ho Files: " ++ show fs'
      else do
    let removeLink' fn = catch  (removeLink fn)  (\_ -> return ())
    let g (fn:fs) = do
            f fn
            mapM_ (l fn) fs
            return ()
        g [] = error "Ho.g: shouldn't happen"
        l fn fn' = do
            wdump FD.Progress $ do
                fn_ <- shortenPath fn
                fn_' <- shortenPath fn'
                when (optNoWriteHo options) $ putErr "Skipping "
                putErrLn $ "Linking haskell object file:" <+> fn_' <+> "to" <+> fn_
            if optNoWriteHo options then return () else do
            let tfn = fn' ++ ".tmp"
            removeLink' tfn
            createLink fn tfn
            rename tfn fn'
        f fn = do
            wdump FD.Progress $ do
                when (optNoWriteHo options) $ putErr "Skipping "
                fn' <- shortenPath fn
                putErrLn $ "Writing haskell object file:" <+> fn'
            if optNoWriteHo options then return () else do
            let tfn = fn ++ ".tmp"
            let theho =  mapHoBodies eraseE ho
                cfflbs = mkCFFfile cff_magic [
                    (cff_jhdr, compress $ encode header),
                    (cff_idep, compress $ encode idep),
                    (cff_defs, compress $ encode $ hoExp theho),
                    (cff_core, compress $ encode $ hoBuild theho)]
            LBS.writeFile tfn cfflbs
            rename tfn fn
    g fs



hsModuleRequires x = Module "Jhc.Prim":ans where
    noPrelude =   or $ not (optPrelude options):[ opt == c | opt <- hsModuleOptions x, c <- ["-N","--noprelude"]]
    ans = snub $ (if noPrelude then id else  (Module "Prelude":)) [  hsImportDeclModule y | y <- hsModuleImports x]

searchPaths :: String -> [(String,String)]
searchPaths m = ans where
    f m | (xs,'.':ys) <- span (/= '.') m = let n = (xs ++ "/" ++ ys) in m:f n
        | otherwise = [m]
    ans = [ (root ++ suf,root ++ ".ho") | i <- optIncdirs options, n <- f m, suf <- [".hs",".lhs"], let root = i ++ "/" ++ n]


parseHsSource :: String -> LBS.ByteString -> IO HsModule
parseHsSource fn lbs = do
    let txt = UTF8.fromUTF $ LBS.unpack lbs
    let f s = opt where
            Just opt = fileOptions opts `mplus` Just options where
            s' = if "shl." `isPrefixOf` reverse fn  then unlit fn s else s
            opts = concat [ words as | (x,as) <- parseOptions s', x `elem` ["OPTIONS","JHC_OPTIONS","OPTIONS_JHC"]]
    let fopts s = s `member` optFOptsSet opt where opt = f (take 1024 txt)
    s <- case () of
        _ | fopts FO.Cpp -> readSystem "cpp" ["-D__JHC__","-CC","-traditional", "--", fn]
          | fopts FO.M4 ->  readSystem "m4" ["-D__JHC__", "-s", fn]
          | otherwise -> return txt
    let s' = if "shl." `isPrefixOf` reverse fn  then unlit fn s'' else s''
        s'' = case s of
            '#':' ':_   -> '\n':s                --  line pragma
            '#':'l':'i':'n':'e':' ':_  -> '\n':s --  line pragma
            '#':'!':_ -> dropWhile (/= '\n') s   --  hashbang
            _ -> s
    case runParserWithMode (parseModeOptions $ f s) { parseFilename = fn } parse  s'  of
                      ParseOk ws e -> processErrors ws >> return e
                      ParseFailed sl err -> putErrDie $ show sl ++ ": " ++ err


mapHoBodies  :: (E -> E) -> Ho -> Ho
mapHoBodies sm ho = ho { hoBuild = g (hoBuild ho) } where
    g ho = ho { hoEs = map f (hoEs ho) , hoRules =  runIdentity (E.Rules.mapBodies (return . sm) (hoRules ho)) }
    f (t,e) = (t,sm e)


eraseE :: E -> E
eraseE e = runIdentity $ f e where
    f (EVar tv) = return $ EVar  tvr { tvrIdent = tvrIdent tv }
    f e = emapE f e



---------------------------------
-- library specific routines
---------------------------------

buildLibrary :: (CollectedHo -> Ho -> IO CollectedHo)
             -> (CollectedHo -> [HsModule] -> IO (CollectedHo,Ho))
             -> FilePath
             -> IO ()
buildLibrary ifunc func = ans where
    ans fp = do
        (desc,name,hmods,emods) <- parse fp
        let allmods  = sort (emods ++ hmods)
        (cho,libDeps,ho) <- findModule (map Left (emods ++ hmods)) ifunc func
        let unknownMods = [ m | m <- mkeys (hoExports $ hoExp ho), m `notElem` allmods  ]
        mapM_ ((putStrLn . ("*** Module included in library that is not in export list: " ++)) . show) unknownMods
        let outName = case optOutName options of
                "hs.out" -> name ++ ".hl"
                fn -> fn
        let pdesc = [(toAtom n, packString v) | (n,v) <- ("jhc-hl-filename",outName):("jhc-description-file",fp):("jhc-compiled-by",versionString):desc, n /= "exposed-modules" ]
        let lhash = MD5.md5String (show $ choFiles cho)
        let hoh =  HoHeader {
                hohHash = lhash,
                hohDepends = [ (m,MD5.emptyHash) | m <- mkeys (hoExports $ hoExp ho)],
                hohModDepends = snds libDeps,
                hohMetaInfo = pdesc
                }
        recordHoFile ho (HoIDeps Map.empty) [outName] hoh

    -- parse library description file
    parse fp = do
        putVerboseLn $ "Creating library from description file: " ++ show fp
        desc <- readDescFile fp
        when verbose2 $ mapM_ print desc
        let field x = lookup x desc
            jfield x = maybe (fail $ "createLibrary: description lacks required field " ++ show x) return $ field x
            mfield x = maybe [] (words . map (\c -> if c == ',' then ' ' else c)) $ field x
        name <- jfield "name"
        vers <- jfield "version"
        let hmods = map Module $ snub $ mfield "hidden-modules"
            emods = map Module $ snub $ mfield "exposed-modules"
        return (desc,name ++ "-" ++ vers,hmods,emods)


------------------------------------
-- dumping contents of a ho file
------------------------------------


instance DocLike d => PPrint d SrcLoc where
    pprint sl = tshow sl

{-# NOINLINE dumpHoFile #-}
dumpHoFile :: String -> IO ()
dumpHoFile fn = do
    (hoh,idep,ho) <- readHoFile fn
    let hoB = hoBuild ho
        hoE = hoExp ho
    putStrLn fn
    when (not $ Map.null (hoIDeps idep)) $ putStrLn $ "IDeps:\n" <>  vcat (map pprint . Map.toList $ hoIDeps idep)
    when (not $ Prelude.null (hohDepends hoh)) $ putStrLn $ "Dependencies:\n" <>  vcat (map pprint . sortUnder fst $ hohDepends hoh)
    when (not $ Prelude.null (hohModDepends hoh)) $ putStrLn $ "ModDependencies:\n" <>  vcat (map pprint $ hohModDepends hoh)
    putStrLn $ "HoHash:" <+> pprint (hohHash hoh)
    putStrLn $ "MetaInfo:\n" <> vcat (sort [text (' ':' ':fromAtom k) <> char ':' <+> show v | (k,v) <- hohMetaInfo hoh])
    putStrLn $ "Modules contained:" <+> tshow (mkeys $ hoExports hoE)
    putStrLn $ "number of definitions:" <+> tshow (size $ hoDefs hoE)
    putStrLn $ "hoAssumps:" <+> tshow (size $ hoAssumps hoB)
    putStrLn $ "hoFixities:" <+> tshow (size $  hoFixities hoB)
    putStrLn $ "hoKinds:" <+> tshow (size $  hoKinds hoB)
    putStrLn $ "hoClassHierarchy:" <+> tshow (size $  hoClassHierarchy hoB)
    putStrLn $ "hoTypeSynonyms:" <+> tshow (size $  hoTypeSynonyms hoB)
    putStrLn $ "hoDataTable:" <+> tshow (size $  hoDataTable hoB)
    putStrLn $ "hoEs:" <+> tshow (size $  hoEs hoB)
    putStrLn $ "hoRules:" <+> tshow (size $  hoRules hoB)
    wdump FD.Exports $ do
        putStrLn "---- exports information ----";
        CharIO.putStrLn $  (pprint $ hoExports hoE :: String)
    wdump FD.Defs $ do
        putStrLn "---- defs information ----";
        CharIO.putStrLn $  (pprint $ hoDefs hoE :: String)
    when (dump FD.Kind) $ do
        putStrLn "---- kind information ----";
        CharIO.putStrLn $  (pprint $ hoKinds hoB :: String)
    when (dump FD.ClassSummary) $ do
        putStrLn "---- class summary ---- "
        printClassSummary (hoClassHierarchy hoB)
    when (dump FD.Class) $
         do {putStrLn "---- class hierarchy ---- ";
             printClassHierarchy (hoClassHierarchy hoB)}
    let rules = hoRules hoB
    wdump FD.Rules $ putStrLn "  ---- user rules ---- " >> printRules RuleUser rules
    wdump FD.Rules $ putStrLn "  ---- user catalysts ---- " >> printRules RuleCatalyst rules
    wdump FD.RulesSpec $ putStrLn "  ---- specializations ---- " >> printRules RuleSpecialization rules
    wdump FD.Datatable $ do
         putStrLn "  ---- data table ---- "
         putDocM CharIO.putStr (showDataTable (hoDataTable hoB))
         putChar '\n'
    wdump FD.Types $ do
        putStrLn " ---- the types of identifiers ---- "
        putStrLn $ PPrint.render $ pprint (hoAssumps hoB)
    wdump FD.Core $ do
        putStrLn " ---- lambdacube  ---- "
        mapM_ (\ (v,lc) -> putChar '\n' >> printCheckName'' (hoDataTable hoB) v lc) (hoEs hoB)
    where
    printCheckName'' :: DataTable -> TVr -> E -> IO ()
    printCheckName'' _dataTable tvr e = do
        when (dump FD.EInfo || verbose2) $ putStrLn (show $ tvrInfo tvr)
        putStrLn (render $ hang 4 (pprint tvr <+> text "::" <+> pprint (tvrType tvr)))
        putStrLn (render $ hang 4 (pprint tvr <+> equals <+> pprint e))

