/*##############################################################################

    HPCC SYSTEMS software Copyright (C) 2012 HPCC Systems.

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
############################################################################## */

import $.^.Setup;
import Setup.Options;
import Setup.TS;

EXPORT TextSearch := FUNCTION

INCLUDE_DEBUG_INFO := false;
import lib_stringlib;

MaxTerms            := TS.MaxTerms;
MaxStages           := TS.MaxStages;
MaxProximity        := TS.MaxProximity;
MaxWildcard     := TS.MaxWildcard;
MaxMatchPerDocument := TS.MaxMatchPerDocument;
MaxFilenameLength := TS.MaxFilenameLength;
MaxActions       := TS.MaxActions;

kindType        := TS.kindType;
sourceType      := TS.sourceType;
wordCountType   := TS.wordCountType;
segmentType     := TS.segmentType;
wordPosType     := TS.wordPosType;
docPosType      := TS.docPosType;
documentId      := TS.documentId;
termType        := TS.termType;
distanceType    := TS.distanceType;
stageType       := TS.stageType;
dateType        := TS.dateType;
matchCountType  := unsigned2;
wordType        := TS.wordType;
wordFlags       := TS.wordFlags;
wordIdType      := TS.wordIdType;

//May want the following, probably not actually implemented as an index - would save having dpos in the index, but more importantly storing it in the candidate match results because the mapping could be looked up later.
wordIndexRecord := TS.wordIndexRecord;

MaxWipWordOrAlias  := 4;
MaxWipTagContents  := 65535;
MaxWordsInDocument := 1000000;
MaxWordsInSet      := 20;

///////////////////////////////////////////////////////////////////////////////////////////////////////////

actionEnum := ENUM(
    None = 0,

//Minimal operations required to implement the searching.
    ReadWord,           // termNum, source, segment, word, wordFlagMask, wordFlagCompare,
    ReadWordSet,        // termNum, source, segment, words, wordFlagMask, wordFlagCompare,
    AndTerms,           //
    OrTerms,            //
    AndNotTerms,        //
    PhraseAnd,          //
    ProximityAnd,       // distanceBefore, distanceAfter
    MofNTerms,          // minMatches, maxMatches
    RankMergeTerms,     // left outer join
    RollupByDocument,   // grouped rollup by document.
    NormalizeMatch,     // Normalize proximity records.
    Phrase1To5And,      // For testing range limits
    GlobalAtLeast,
    ContainedAtLeast,
    TagContainsSearch,  // Used for the outermost IN() expression - check it overlaps and rolls up
    TagContainsTerm,    // Used for an inner tag contains - checks, but doesn't roll up
    TagNotContainsTerm, //
    SameContainer,
    NotSameContainer,   //
    MofNContainer,      //
    RankContainer,      // NOTIMPLEMENTED
    OverlapProximityAnd,

//The following aren't very sensible as far as text searching goes, but are here to test the underlying functionality
    AndJoinTerms,       // join on non-proximity
    AndNotJoinTerms,    //
    MofNJoinTerms,      // minMatches, maxMatches
    RankJoinTerms,      // left outer join
    ProximityMergeAnd,  // merge join on proximity
    RollupContainer,
    PositionFilter,     // a filter on position - which will cause lots of rows to be skipped.

//Possibly sensible
    ChooseRange,
    ButNotTerms,
    ButNotJoinTerms,

    PassThrough,
    PositionNotFilter,  // a non equality filter on position - unlikely to cause any rows to skip
    Last,

    //The following are only used in the production
    FlagModifier,       // wordFlagMask, wordFlagCompare
    QuoteModifier,      //
    Max
);

//  FAIL(stageType, 'Missing entry: ' + (string)action));

boolean definesTerm(actionEnum action) :=
    (action in [actionEnum.ReadWord, actionEnum.ReadWordSet]);

booleanRecord := { boolean value };
stageRecord := { stageType stage };
termRecord := { termType term };
stageMapRecord := { stageType from; stageType to };
wipRecord := { wordPosType wip; };
wordRecord := { wordType word; };
wordSet := set of wordType;
stageSet := set of stageType;

createStage(stageType stage) := transform(stageRecord, self.stage := stage);
createTerm(termType term) := transform(termRecord, self.term := term);

//should have an option to optimize the order
searchRecord :=
            RECORD  //,PACK
stageType       stage;
termType        term;
actionEnum      action;

dataset(stageRecord) inputs{maxcount(MaxStages)};

distanceType    maxWip;
distanceType    maxWipChild;
distanceType    maxWipLeft;
distanceType    maxWipRight;

//The item being searched for
wordType        word;
dataset(wordRecord) words{maxcount(maxWordsInSet)};
wordFlags       wordFlagMask;
wordFlags       wordFlagCompare;
sourceType      source;
segmentType     segment;
wordPosType     seekWpos;
integer4        priority;

//Modifiers for the connector/filter
distanceType    maxDistanceRightBeforeLeft;
distanceType    maxDistanceRightAfterLeft;
matchCountType  minMatches;
matchCountType  maxMatches;
dataset(termRecord) termsToProcess{maxcount(MaxTerms)};     // which terms to count with an atleast

#if (INCLUDE_DEBUG_INFO)
string          debug{maxlength(200)}
#end
            END;

childMatchRecord := RECORD
wordPosType         wpos;
wordPosType         wip;
termType            term;               // slightly different from the stage - since stages can get transformed.
                END;


simpleUserOutputRecord :=
        record
unsigned2           source;
unsigned6           subDoc;
wordPosType         wpos;
wordPosType         wip;
docPosType          line;
unsigned4           column;
dataset(childMatchRecord) words{maxcount(MaxProximity)};
        end;



StageSetToDataset(stageSet x) := dataset(x, stageRecord);
StageDatasetToSet(dataset(stageRecord) x) := set(x, stage);

hasSingleRowPerMatch(actionEnum kind) :=
    (kind IN [  actionEnum.ReadWord,
                actionEnum.ReadWordSet,
                actionEnum.PhraseAnd,
                actionEnum.ProximityAnd,
                actionEnum.ContainedAtLeast,
                actionEnum.TagContainsTerm,
                actionEnum.TagContainsSearch,
                actionEnum.OverlapProximityAnd]);

inheritsSingleRowPerMatch(actionEnum kind) :=
    (kind IN [  actionEnum.OrTerms,
//              actionEnum.AndNotTerms,                 // move container inside an andnot
                actionEnum.TagNotContainsTerm,
                actionEnum.NotSameContainer]);

string1 TF(boolean value) := IF(value, 'T', 'F');

///////////////////////////////////////////////////////////////////////////////////////////////////////////
// Matches

//Deliberately a different order from the index to ensure that the mapping from output to input formats is done consistently.
matchRecord :=  RECORD
wordPosType         wip;
docPosType          dpos;
wordPosType         wpos;
stageType           term;
documentId          doc;
segmentType         segment;
dataset(childMatchRecord) children{maxcount(MaxProximity)};
                END;

createChildMatch(wordPosType wpos, wordPosType wip, termType term) := transform(childMatchRecord, self.wpos := wpos; self.wip := wip; self.term := term);
SetOfInputs := set of dataset(matchRecord);

//-------------------------------------------------------------------------------------------------------------
//-------------------------------------------------------------------------------------------------------------
//---------------------------------------- Code for executing queries -----------------------------------------
//-------------------------------------------------------------------------------------------------------------
//-------------------------------------------------------------------------------------------------------------

createChildrenFromMatch(matchRecord l) := function
    rawChildren := IF(exists(l.children), l.children, dataset(row(createChildMatch(l.wpos, l.wip, l.term))));
    sortedChildren := sorted(rawChildren, wpos, wip, assert);
    return sortedChildren;
end;

combineChildren(dataset(childMatchRecord) l, dataset(childMatchRecord) r) := function
    lSorted := sorted(l, wpos, wip, assert);
    rSorted := sorted(r, wpos, wip, assert);
    mergedDs := merge(lSorted, rSorted, sorted(wpos, wip, term));
    return dedup(mergedDs, wpos, wip, term);
end;

SearchExecutor(dataset(TS.wordIndexRecord) wordIndex, unsigned4 internalFlags) := MODULE

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Matching helper functions

    EXPORT matchSearchFlags(wordIndex wIndex, searchRecord search) :=
        keyed(search.segment = 0 or wIndex.segment = search.segment, opt) AND
        ((wIndex.flags & search.wordFlagMask) = search.wordFlagCompare);

    EXPORT matchSingleWord(wordIndex wIndex, searchRecord search) :=
        keyed(wIndex.kind = kindType.TextEntry and wIndex.word = search.word) AND
        matchSearchFlags(wIndex, search);

    EXPORT matchManyWord(wordIndex wIndex, searchRecord search) :=
        keyed(wIndex.kind = kindType.TextEntry and wIndex.word in set(search.words, word)) AND
        matchSearchFlags(wIndex, search);

    EXPORT matchSearchSource(wordIndex wIndex, searchRecord search) :=
        keyed(search.source = 0 OR TS.docMatchesSource(wIndex.doc, search.source), opt);

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ReadWord

    EXPORT doReadWord(searchRecord search) := FUNCTION

        matches := sorted(wordIndex, doc, segment, wpos, wip)(
                            matchSingleWord(wordIndex, search) AND
                            matchSearchSource(wordIndex, search));

        matchRecord createMatchRecord(wordIndexRecord ds) := transform
            self := ds;
            self.term := search.term;
            self := [];
        end;

        steppedMatches :=   IF(search.priority <> 0,
                                stepped(matches, doc, segment, wpos, priority(search.priority)),
                                stepped(matches, doc, segment, wpos)
                            );

        //limit seek look ahead to allow test cases to be written for global stepping with priorities
        projected := project(steppedMatches, createMatchRecord(left), keyed, hint(maxseeklookahead(2)));

        return projected;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ReadWord

    EXPORT doReadWordSet(searchRecord search) := FUNCTION

        matches := sorted(wordIndex, doc, segment, wpos, wip)(
                            matchManyWord(wordIndex, search) AND
                            matchSearchSource(wordIndex, search));

        matchRecord createMatchRecord(wordIndexRecord ds) := transform
            self := ds;
            self.term := search.term;
            self := [];
        end;

        steppedMatches :=   IF(search.priority <> 0,
                                stepped(matches, doc, segment, wpos, priority(search.priority)),
                                stepped(matches, doc, segment, wpos)
                            );

        projected := project(steppedMatches, createMatchRecord(left), keyed);

        return projected;
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OrTerms

    EXPORT doOrTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return merge(inputs, doc, segment, wpos, dedup, SORTED(doc, segment, wpos));        // MORE  option to specify priority?
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // AndTerms

    EXPORT doAndTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc), doc, segment, wpos, dedup, internal(internalFlags));        // MORE  option to specify priority?
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // AndNotTerms

    EXPORT doAndNotTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc), doc, segment, wpos, left only, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ButNotTerms

    EXPORT doButNotTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc and left.segment=right.segment) and
                                 (LEFT.wpos BETWEEN RIGHT.wpos AND RIGHT.wpos+RIGHT.wip), doc, segment, wpos, left only, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ButNotJoinTerms

    EXPORT doButNotJoinTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc and left.segment=right.segment) and
                                 (LEFT.wpos BETWEEN RIGHT.wpos AND RIGHT.wpos+RIGHT.wip), transform(left), sorted(doc, segment, wpos), left only, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // RankMergeTerms

    EXPORT doRankMergeTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc), doc, segment, wpos, left outer, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // MofN mergejoin

    EXPORT doMofNTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc), doc, segment, wpos, dedup, mofn(search.minMatches, search.maxMatches), internal(internalFlags));        // MORE  option to specify priority?
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Join varieties - primarily for testing

    //Note this testing transform wouldn't work correctly with proximity operators as inputs.
    SHARED matchRecord createDenormalizedMatch(searchRecord search, matchRecord l, dataset(matchRecord) matches) := transform

        wpos := min(matches, wpos);
        wend := max(matches, wpos + wip);

        self.wpos := wpos;
        self.wip := wend - wpos;
        self.children := sort(normalize(matches, 1, createChildMatch(LEFT.wpos, LEFT.wip, LEFT.term)), wpos, wip, term);
        self.term := search.term;
        self := l;
    end;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // AndJoinTerms

    EXPORT doAndJoinTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc) and (left.wpos <> right.wpos), createDenormalizedMatch(search, LEFT, ROWS(left)), sorted(doc, segment, wpos), internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // AndNotJoinTerms

    EXPORT doAndNotJoinTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc), createDenormalizedMatch(search, LEFT, ROWS(left)), sorted(doc, segment, wpos), left only, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // RankJoinTerms

    EXPORT doRankJoinTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc), createDenormalizedMatch(search, LEFT, ROWS(left)), sorted(doc, segment, wpos), left outer, internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // MofN Join

    EXPORT doMofNJoinTerms(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc), createDenormalizedMatch(search, LEFT, ROWS(left)), sorted(doc, segment, wpos), mofn(search.minMatches, search.maxMatches), internal(internalFlags));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // PhraseAnd

    steppedPhraseCondition(matchRecord l, matchRecord r, distanceType maxWip) :=
            (l.doc = r.doc) and (l.segment = r.segment) and
            (r.wpos between l.wpos+1 and l.wpos+maxWip);

    EXPORT doPhraseAnd(searchRecord search, SetOfInputs inputs) := FUNCTION

        steppedCondition(matchRecord l, matchRecord r) := steppedPhraseCondition(l, r, search.maxWipLeft);

        condition(matchRecord l, matchRecord r) :=
            (r.wpos = l.wpos + l.wip);

        matchRecord createMatch(matchRecord l, dataset(matchRecord) allRows) := transform
            self.wip := sum(allRows, wip);
            self.term := search.term;
            self := l;
        end;

        matches := join(inputs, STEPPED(steppedCondition(left, right)) and condition(LEFT, RIGHT), createMatch(LEFT, ROWS(LEFT)), sorted(doc, segment, wpos), internal(internalFlags));

        return matches;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // PhraseAnd

    steppedPhrase1To5Condition(matchRecord l, matchRecord r, distanceType maxWip) :=
            (l.doc = r.doc) and (l.segment = r.segment) and
            (r.wpos between l.wpos+1 and l.wpos+5);

    EXPORT doPhrase1To5And(searchRecord search, SetOfInputs inputs) := FUNCTION

        steppedCondition(matchRecord l, matchRecord r) := steppedPhrase1To5Condition(l, r, search.maxWipLeft);

        condition(matchRecord l, matchRecord r) :=
            (r.wpos = l.wpos + l.wip);

        matchRecord createMatch(matchRecord l, dataset(matchRecord) allRows) := transform
            self.wip := sum(allRows, wip);
            self.term := search.term;
            self := l;
        end;

        matches := join(inputs, STEPPED(steppedCondition(left, right)) and condition(LEFT, RIGHT), createMatch(LEFT, ROWS(LEFT)), sorted(doc, segment, wpos), internal(internalFlags));

        return matches;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // GlobalAtLeast

    EXPORT doGlobalAtLeast(searchRecord search, SetOfInputs inputs) := FUNCTION
        input := inputs[1];
        groupedInput := group(input, doc);
        filtered := having(groupedInput, count(rows(left)) >= search.minMatches);
        return group(filtered);
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ContainedAtLeast

    //if container count the number of entries for each unique container == each unique (wpos)
    //may possibly be issues with multiple containers starting at the same position
    EXPORT doContainedAtLeastV1(searchRecord search, SetOfInputs inputs) := FUNCTION
        input := inputs[1];
        groupedInput := group(input, doc, segment, wpos);
        filtered := having(groupedInput, count(rows(left)) >= search.minMatches);
        return group(filtered);
    END;


    EXPORT doContainedAtLeast(searchRecord search, SetOfInputs inputs) := FUNCTION
        input := inputs[1];

        return input(count(children(term in set(search.termsToProcess, term))) >= search.minMatches);
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SameContainer

    matchRecord mergeContainers(termType term, matchRecord l, matchRecord r) := transform
        leftChildren := sorted(l.children, wpos, wip, assert);
        rightChildren := sorted(r.children, wpos, wip, assert);
        self.children := merge(leftChildren, rightChildren, sorted(wpos, wip, term), dedup);
        self.term := term;
        self := l;
    end;


    EXPORT doSameContainerOld(searchRecord search, SetOfInputs inputs) := FUNCTION
        return join(inputs, STEPPED(left.doc = right.doc and left.segment = right.segment and left.wpos = right.wpos) and (left.wip = right.wip), mergeContainers(search.term, LEFT, RIGHT), sorted(doc, segment, wpos), internal(internalFlags));
    END;

    EXPORT doSameContainer(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc and left.segment = right.segment and left.wpos = right.wpos) and (left.wip = right.wip), sorted(doc, segment, wpos), internal(internalFlags));
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // AndNotSameContainer

    EXPORT doNotSameContainer(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc and left.segment = right.segment and left.wpos = right.wpos) and (left.wip = right.wip), doc, segment, wpos, left only, internal(internalFlags));
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // M of N container

    EXPORT doMofNContainer(searchRecord search, SetOfInputs inputs) := FUNCTION
        return mergejoin(inputs, STEPPED(left.doc = right.doc and left.segment = right.segment and left.wpos = right.wpos) and (left.wip = right.wip), doc, segment, wpos, mofn(search.minMatches, search.maxMatches), internal(internalFlags));        // MORE  option to specify priority?
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ReadContainer  (used internally by in/notin)

    EXPORT doReadContainer(searchRecord search) := FUNCTION

        matches := sorted(wordIndex, doc, segment, wpos, wip)(
                            keyed(kind = kindType.OpenTagEntry and word = search.word) AND
                            matchSearchFlags(wordIndex, search) AND
                            matchSearchSource(wordIndex, search));

        matchRecord createMatchRecord(wordIndexRecord ds) := transform
            self := ds;
            self.term := search.term;
            self := []
        end;

        steppedMatches := stepped(matches, doc, segment, wpos);

        projected := project(steppedMatches, createMatchRecord(left));

        return projected;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // RollupContainer - used for in transformation of TagContainsSearch(a and b)

    EXPORT rollupContainerContents(searchRecord search, dataset(matchRecord) input) := FUNCTION
        groupedByPosition := group(input, doc, segment, wpos);

        matchRecord combine(matchRecord l, dataset(matchRecord) matches) := transform

            //each child record already contains an entry for the container.
            //ideally we want an nary-merge,dedup to combine the children
            //self.children := merge(SET(matches, children), wpos, wip, term, dedup);       if we had the syntax
            allMatches := sort(matches.children, wpos, wip, term);
            self.children := dedup(allMatches, wpos, wip, term);
            self.term := search.term;
            self := l;
        end;
        return rollup(groupedByPosition, group, combine(LEFT, ROWS(LEFT)));
    END;

    EXPORT doRollupContainer(searchRecord search, SetOfInputs inputs) := FUNCTION
        return rollupContainerContents(search, inputs[1]);
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    //PositionFilter

    EXPORT doPositionFilter(searchRecord search, SetOfInputs inputs) := FUNCTION
        return (inputs[1])(wpos = search.seekWpos);
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    //PositionFilter

    EXPORT doPositionNotFilter(searchRecord search, SetOfInputs inputs) := FUNCTION
        return (inputs[1])(wpos <> search.seekWpos);
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    //ChooseRange

    EXPORT doChooseRange(searchRecord search, SetOfInputs inputs) := FUNCTION
        return choosen(inputs[1], search.maxMatches - search.minMatches + 1, search.minMatches);
    END;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // TagContainsTerm      - used for an element within a complex container expression

    //MORE: This should probably always add container, term, and children of term, so that entries for proximity operators are
    //      included in the children list - so that atleast on a proximity can be implemented correctly.

    SHARED matchRecord combineContainer(searchRecord search, matchRecord container, matchRecord terms) := transform
        containerEntry := row(transform(childMatchRecord, self.wpos := container.wpos; self.wip := container.wip; self.term := container.term));
        SELF.children := combineChildren(dataset(containerEntry), createChildrenFromMatch(terms));
        self.term := search.term;
        self := container;
    end;

    SHARED boolean isTermInsideTag(matchRecord term, matchRecord container) :=
            STEPPED(term.doc = container.doc and term.segment = container.segment) and
                    ((term.wpos >= container.wpos) and (term.wpos + term.wip <= container.wpos + container.wip));


    EXPORT doTagContainsTerm(searchRecord search, SetOfInputs inputs) := FUNCTION
        matchedTermInput := inputs[1];
        containerInput := doReadContainer(search);
        combined := join([matchedTermInput, containerInput],    isTermInsideTag(left, right),
                    combineContainer(search, RIGHT, LEFT), sorted(doc, segment, wpos));
        return combined;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // TagContainsSearch

    EXPORT doTagContainsSearch(searchRecord search, SetOfInputs inputs) := FUNCTION
        return rollupContainerContents(search, doTagContainsTerm(search, inputs));
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // TagNotContainsTerm

    EXPORT doTagNotContainsTerm(searchRecord search, SetOfInputs inputs) := FUNCTION
        matchedTermInput := inputs[1];
        containerInput := doReadContainer(search);
        return mergejoin([matchedTermInput, containerInput], isTermInsideTag(left, right), sorted(doc, segment, wpos), left only);
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ProximityAnd

    SHARED steppedProximityCondition(matchRecord l, matchRecord r, distanceType maxWipLeft, distanceType maxWipRight, distanceType maxDistanceRightBeforeLeft, distanceType maxDistanceRightAfterLeft) := function
            // if maxDistanceRightBeforeLeft is < 0 it means it must follow, so don't add maxWipRight
            maxRightBeforeLeft := IF(maxDistanceRightBeforeLeft >= 0, maxDistanceRightBeforeLeft + maxWipRight, maxDistanceRightBeforeLeft);
            maxRightAfterLeft := IF(maxDistanceRightAfterLeft >= 0, maxDistanceRightAfterLeft + maxWipLeft, maxDistanceRightAfterLeft);

            return
                (l.doc = r.doc) and (l.segment = r.segment) and
                (r.wpos + maxRightBeforeLeft >= l.wpos) and             // (right.wpos + right.wip + maxRightBeforeLeft >= left.wpos)
                (r.wpos <= l.wpos + (maxRightAfterLeft));               // (right.wpos <= left.wpos + left.wip + maxRightAfterLeft)
    end;


    EXPORT doProximityAnd(searchRecord search, SetOfInputs inputs) := FUNCTION

        steppedCondition(matchRecord l, matchRecord r) := steppedProximityCondition(l, r, search.maxWipLeft, search.maxWipRight, search.maxDistanceRightBeforeLeft, search.maxDistanceRightAfterLeft);

        condition(matchRecord l, matchRecord r) :=
            (r.wpos + r.wip + search.maxDistanceRightBeforeLeft >= l.wpos) and
            (r.wpos <= l.wpos + l.wip + search.maxDistanceRightAfterLeft);

        overlaps(wordPosType wpos, childMatchRecord r) := (wpos between r.wpos and r.wpos + (r.wip - 1));

        createMatch(matchRecord l, matchRecord r) := function

            wpos := min(l.wpos, r.wpos);
            wend := max(l.wpos + l.wip, r.wpos + r.wip);

            leftChildren := createChildrenFromMatch(l);
            rightChildren := createChildrenFromMatch(r);
            anyOverlaps := exists(join(leftChildren, rightChildren,
                                   overlaps(left.wpos, right) or overlaps(left.wpos+(left.wip-1), right) or
                                   overlaps(right.wpos, left) or overlaps(right.wpos+(right.wip-1), left), all));

        //Check for any overlaps between the words, should be disjoint.
            matchRecord matchTransform := transform, skip(anyOverlaps)
                self.wpos := wpos;
                self.wip := wend - wpos;
                self.children := merge(leftChildren, rightChildren, sorted(wpos, wip, term), dedup);
                self.term := search.term;
                self := l;
            end;

            return matchTransform;
        end;

        matches := join(inputs, STEPPED(steppedCondition(left, right)) and condition(LEFT, RIGHT), createMatch(LEFT, RIGHT), sorted(doc, segment, wpos));

        return matches;
    END;


    EXPORT doProximityMergeAnd(searchRecord search, SetOfInputs inputs) := FUNCTION

        steppedCondition(matchRecord l, matchRecord r) := steppedProximityCondition(l, r, search.maxWipLeft, search.maxWipRight, search.maxDistanceRightBeforeLeft, search.maxDistanceRightAfterLeft);

        condition(matchRecord l, matchRecord r) :=
            (r.wpos + r.wip + search.maxDistanceRightBeforeLeft >= l.wpos) and
            (r.wpos <= l.wpos + l.wip + search.maxDistanceRightAfterLeft);

        overlaps(wordPosType wpos, childMatchRecord r) := (wpos between r.wpos and r.wpos + (r.wip - 1));

        anyOverlaps (matchRecord l, matchRecord r) := function

            wpos := min(l.wpos, r.wpos);
            wend := max(l.wpos + l.wip, r.wpos + r.wip);

            leftChildren := createChildrenFromMatch(l);
            rightChildren := createChildrenFromMatch(r);
            anyOverlaps := exists(join(leftChildren, rightChildren,
                                   overlaps(left.wpos, right) or overlaps(left.wpos+(left.wip-1), right) or
                                   overlaps(right.wpos, left) or overlaps(right.wpos+(right.wip-1), left), all));

            return anyOverlaps;
        end;

        matches := mergejoin(inputs, STEPPED(steppedCondition(left, right)) and condition(LEFT, RIGHT) and not anyOverlaps(LEFT,RIGHT), sorted(doc, segment, wpos));

        return matches;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OverlapProximityAnd

    EXPORT doOverlapProximityAnd(searchRecord search, SetOfInputs inputs) := FUNCTION

        steppedCondition(matchRecord l, matchRecord r) :=
                (l.doc = r.doc) and (l.segment = r.segment) and
                (r.wpos + search.maxWipRight >= l.wpos) and
                (r.wpos <= l.wpos + search.maxWipLeft);

        condition(matchRecord l, matchRecord r) :=
            (r.wpos + r.wip >= l.wpos) and (r.wpos <= l.wpos + l.wip);


        createMatch(matchRecord l, matchRecord r) := function

            wpos := min(l.wpos, r.wpos);
            wend := max(l.wpos + l.wip, r.wpos + r.wip);

            leftChildren := createChildrenFromMatch(l);
            rightChildren := createChildrenFromMatch(r);

            matchRecord matchTransform := transform
                self.wpos := wpos;
                self.wip := wend - wpos;
                self.children := merge(leftChildren, rightChildren, sorted(wpos, wip, term), dedup);
                self.term := search.term;
                self := l;
            end;

            return matchTransform;
        end;

        matches := join(inputs, STEPPED(steppedCondition(left, right)) and condition(LEFT, RIGHT), createMatch(LEFT, RIGHT), sorted(doc, segment, wpos));

        return matches;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Normalize denormalized proximity records

    EXPORT doNormalizeMatch(searchRecord search, SetOfInputs inputs) := FUNCTION

        matchRecord createNorm(matchRecord l, unsigned c) := transform
            hasChildren := count(l.children) <> 0;
            curChild := l.children[NOBOUNDCHECK c];
            self.wpos := if (hasChildren, curChild.wpos, l.wpos);
            self.wip := if (hasChildren, curChild.wip, l.wip);
            self.term := search.term;
            self.children := [];
            self := l;
        end;

        normalizedRecords := normalize(inputs[1], MAX(1, count(LEFT.children)), createNorm(left, counter));
        groupedNormalized := group(normalizedRecords, doc, segment);
        sortedNormalized := sort(groupedNormalized, wpos, wip);
        dedupedNormalized := dedup(sortedNormalized, wpos, wip);
        return group(dedupedNormalized);
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Rollup by document

    EXPORT doRollupByDocument(searchRecord search, dataset(matchRecord) input) := FUNCTION
        groupByDocument := group(input, doc);
        dedupedByDocument := rollup(groupByDocument, group, transform(matchRecord, self.doc := left.doc; self.segment := 0; self.wpos := 0; self.wip := 0; self.term := search.term; self := left));
        return dedupedByDocument;
    END;


    ///////////////////////////////////////////////////////////////////////////////////////////////////////////

    EXPORT processStage(searchRecord search, SetOfInputs allInputs) := function
        inputs:= RANGE(allInputs, StageDatasetToSet(search.inputs));
        result := case(search.action,
            actionEnum.ReadWord             => doReadWord(search),
            actionEnum.ReadWordSet          => doReadWordSet(search),
            actionEnum.AndTerms             => doAndTerms(search, inputs),
            actionEnum.OrTerms              => doOrTerms(search, inputs),
            actionEnum.AndNotTerms          => doAndNotTerms(search, inputs),
            actionEnum.PhraseAnd            => doPhraseAnd(search, inputs),
            actionEnum.ProximityAnd         => doProximityAnd(search, inputs),
            actionEnum.MofNTerms            => doMofNTerms(search, inputs),
            actionEnum.RankMergeTerms       => doRankMergeTerms(search, inputs),
            actionEnum.RollupByDocument     => doRollupByDocument(search, allInputs[search.inputs[1].stage]),       // more efficient than way normalize is handled, but want to test both varieties
            actionEnum.NormalizeMatch       => doNormalizeMatch(search, inputs),
            actionEnum.Phrase1To5And        => doPhrase1To5And(search, inputs),
            actionEnum.GlobalAtLeast        => doGlobalAtLeast(search, inputs),
            actionEnum.ContainedAtLeast     => doContainedAtLeast(search, inputs),
            actionEnum.TagContainsTerm      => doTagContainsTerm(search, inputs),
            actionEnum.TagContainsSearch    => doTagContainsSearch(search, inputs),
            actionEnum.TagNotContainsTerm   => doTagNotContainsTerm(search, inputs),
            actionEnum.SameContainer        => doSameContainer(search, inputs),
            actionEnum.NotSameContainer     => doNotSameContainer(search, inputs),
            actionEnum.MofNContainer        => doMofNContainer(search, inputs),
    //      actionEnum.RankContainer        => doRankContainer(search, inputs),

            actionEnum.AndJoinTerms         => doAndJoinTerms(search, inputs),
            actionEnum.AndNotJoinTerms      => doAndNotJoinTerms(search, inputs),
            actionEnum.MofNJoinTerms        => doMofNJoinTerms(search, inputs),
            actionEnum.RankJoinTerms        => doRankJoinTerms(search, inputs),
            actionEnum.ProximityMergeAnd    => doProximityMergeAnd(search, inputs),
            actionEnum.RollupContainer      => doRollupContainer(search, inputs),
            actionEnum.OverlapProximityAnd  => doOverlapProximityAnd(search, inputs),
            actionEnum.PositionFilter       => doPositionFilter(search, inputs),
            actionEnum.ChooseRange          => doChooseRange(search, inputs),
            actionEnum.ButNotTerms          => doButNotTerms(search, inputs),
            actionEnum.ButNotJoinTerms      => doButNotJoinTerms(search, inputs),
            actionEnum.PositionNotFilter    => doPositionNotFilter(search, inputs),

            dataset([], matchRecord));

        //check that outputs from every stage are sorted as required.
        sortedResult := sorted(result, doc, segment, wpos, assert);
        return sortedResult;
    end;

    ///////////////////////////////////////////////////////////////////////////////////////////////////////////
    // Code to actually execute the query:

    EXPORT convertToUserOutput(dataset(matchRecord) results) := function

        simpleUserOutputRecord createUserOutput(matchRecord l) := transform
                self.source := TS.docid2source(l.doc);
                self.subDoc := TS.docid2doc(l.doc);
                self.words := l.children;
                SELF.line := l.dpos DIV TS.MaxColumnsPerLine;
                SELF.column := l.dpos % TS.MaxColumnsPerLine;
                SELF := l;
            END;

        return project(results, createUserOutput(left));
    end;

    EXPORT doExecuteQuery(dataset(searchRecord) queryDefinition, boolean useLocal) := function

        initialResults := dataset([], matchRecord);
        localResults := FUNCTION
            executionPlan := thisnode(global(queryDefinition, opt, few));           // Store globally for efficient access
            results := ALLNODES(LOCAL(graph(initialResults, count(executionPlan), processStage(executionPlan[NOBOUNDCHECK COUNTER], rowset(left)), parallel)));
            RETURN results;
        END;

        globalResults := FUNCTION
            executionPlan := global(queryDefinition, opt, few);         // Store globally for efficient access
            results := graph(initialResults, count(executionPlan), processStage(executionPlan[NOBOUNDCHECK COUNTER], rowset(left)), parallel);
            RETURN results;
        END;

        results := IF(useLocal, localResults, globalResults);
        userOutput := convertToUserOutput(results);

        return userOutput;
    end;

end;

///////////////////////////////////////////////////////////////////////////////////////////////////////////

// A simplified query language
parseQuery(string queryText) := function

searchParseRecord :=
            RECORD(searchRecord)
unsigned        numInputs;
            END;

productionRecord  :=
            record
unsigned        termCount;
dataset(searchParseRecord) actions{maxcount(MaxActions)};
            end;

unknownTerm := (termType)-1;

PRULE := rule type (productionRecord);
ARULE := rule type (searchParseRecord);

///////////////////////////////////////////////////////////////////////////////////////////////////////////

pattern ws := [' ','\t'];

token number    := pattern('-?[0-9]+');
//pattern wordpat   := pattern('[A-Za-z0-9]+');
pattern wordpat := pattern('[A-Za-z][A-Za-z0-9]*');
pattern quotechar   := '"';
token quotedword := quotechar wordpat quotechar;

///////////////////////////////////////////////////////////////////////////////////////////////////////////

searchParseRecord setCapsFlags(wordFlags mask, wordFlags value, searchParseRecord l) := TRANSFORM
    SELF.wordFlagMask := mask;
    SELF.wordFlagCompare := value;
    SELF := l;
END;


PRULE forwardExpr := use(productionRecord, 'ExpressionRule');

ARULE term0
    := quotedword                               transform(searchParseRecord,
                                                    SELF.action := actionEnum.ReadWord;
                                                    SELF.word := StringLib.StringToLowerCase($1[2..length($1)-1]);
                                                    SELF := []
                                                )
    | quotedword ':' number                     transform(searchParseRecord,
                                                    SELF.action := actionEnum.ReadWord;
                                                    SELF.word := StringLib.StringToLowerCase($1[2..length($1)-1]);
                                                    SELF.priority := (typeof(searchParseRecord.priority))$3;
                                                    SELF := []
                                                )
    ;

ARULE capsTerm0
    := term0
    | 'CAPS' '(' term0 ')'                      setCapsFlags(wordFlags.hasUpper, wordFlags.hasUpper, $3)
    | 'NOCAPS' '(' term0 ')'                    setCapsFlags(wordFlags.hasUpper, 0, $3)
    | 'ALLCAPS' '(' term0 ')'                   setCapsFlags(wordFlags.hasUpper+wordFlags.hasLower, wordFlags.hasUpper, $3)
    ;

ARULE term0List
    := term0                                    transform(searchParseRecord,
                                                    SELF.action := actionEnum.ReadWordSet;
                                                    SELF.words := dataset(row(transform(wordRecord, self.word := $1.word)));
                                                    SELF.word := '';
                                                    SELF := $1;
                                                )
    | SELF ',' term0                            transform(searchParseRecord,
                                                    SELF.words := $1.words + dataset(row(transform(wordRecord, self.word := $3.word)));
                                                    SELF.priority := $3.priority;
                                                    SELF := $1;
                                                )
    ;

ARULE capsTerm0List
    := term0List
    | 'CAPS' '(' term0List ')'                  setCapsFlags(wordFlags.hasUpper, wordFlags.hasUpper, $3)
    | 'NOCAPS' '(' term0List ')'                setCapsFlags(wordFlags.hasUpper, 0, $3)
    | 'ALLCAPS' '(' term0List ')'               setCapsFlags(wordFlags.hasUpper+wordFlags.hasLower, wordFlags.hasUpper, $3)
    ;

PRULE termList
    := forwardExpr                              transform(productionRecord, self.termCount := 1; self.actions := $1.actions)
    | SELF ',' forwardExpr                      transform(productionRecord, self.termCount := $1.termCount + 1; self.actions := $1.actions + $3.actions)
    ;

PRULE term1
    := capsTerm0                                transform(productionRecord, self.termCount := 1; self.actions := dataset($1))
    | 'SET' '(' capsTerm0List ')'               transform(productionRecord, self.termCount := 1; self.actions := dataset($3))
    | '(' forwardExpr ')'
    | 'AND' '(' termList ')'                    transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.AndTerms;
//                                                          self.numInputs := count($3.actions) - sum($3.actions, numInputs);
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'ANDNOT' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.AndNotTerms;
                                                            self.numInputs := 2;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'BUTNOT' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ButNotTerms;
                                                            self.numInputs := 2;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'BUTNOTJOIN' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ButNotJoinTerms;
                                                            self.numInputs := 2;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'RANK' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.RankMergeTerms;
                                                            self.numInputs := 2;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'MOFN' '(' number ',' termList ')'        transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.MOfNTerms;
                                                            self.numInputs := $5.termCount;
                                                            SELF.minMatches := (integer)$3;
                                                            SELF.maxMatches := $5.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'MOFN' '(' number ',' number ',' termList ')'     transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $7.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.MOfNTerms;
                                                            self.numInputs := $7.termCount;
                                                            SELF.minMatches := (integer)$3;
                                                            SELF.maxMatches := (integer)$5;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'OR' '(' termList ')'                     transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.OrTerms;
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'PHRASE' '(' termList ')'                 transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.PhraseAnd;
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'PHRASE1TO5' '(' termList ')'             transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.Phrase1To5And;
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'PROXIMITY' '(' forwardExpr ',' forwardExpr ',' number ',' number ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ProximityAnd;
                                                            self.numInputs := 2;
                                                            self.maxDistanceRightBeforeLeft := (integer)$7;
                                                            self.maxDistanceRightAfterLeft := (integer)$9;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'OVERLAP' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.OverlapProximityAnd;
                                                            self.numInputs := 2;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'PRE' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ProximityAnd;
                                                            self.numInputs := 2;
                                                            self.maxDistanceRightBeforeLeft := -1;
                                                            self.maxDistanceRightAfterLeft := MaxWordsInDocument;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'AFT' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ProximityAnd;
                                                            self.numInputs := 2;
                                                            self.maxDistanceRightBeforeLeft := MaxWordsInDocument;
                                                            self.maxDistanceRightAfterLeft := -1;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'PROXMERGE' '(' forwardExpr ',' forwardExpr ',' number ',' number ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ProximityMergeAnd;
                                                            self.numInputs := 2;
                                                            self.maxDistanceRightBeforeLeft := (integer)$7;
                                                            self.maxDistanceRightAfterLeft := (integer)$9;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'ANDJOIN' '(' termList ')'                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.AndJoinTerms;
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'ANDNOTJOIN' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.AndNotJoinTerms;
                                                            self.numInputs := 2;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'MOFNJOIN' '(' number ',' termList ')'        transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.MOfNJoinTerms;
                                                            self.numInputs := $5.termCount;
                                                            SELF.minMatches := (integer)$3;
                                                            SELF.maxMatches := $5.termCount;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'MOFNJOIN' '(' number ',' number ',' termList ')'     transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $7.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.MOfNJoinTerms;
                                                            self.numInputs := $7.termCount;
                                                            SELF.minMatches := (integer)$3;
                                                            SELF.maxMatches := (integer)$5;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'RANKJOIN' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.RankJoinTerms;
                                                            self.numInputs := 2;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'ROLLAND' '(' termList ')'                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.AndTerms;
                                                            self.numInputs := $3.termCount;
                                                            self := [];
                                                        )
                                                    ) + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.RollupByDocument;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'NORM' '(' forwardExpr ')'                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.NormalizeMatch;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'ATLEAST' '(' number ',' forwardExpr ')'  transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.GlobalAtLeast;
                                                            self.minMatches := (integer)$3;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'IN' '(' wordpat ',' forwardExpr ')'      transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.TagContainsSearch;
                                                            self.word := StringLib.StringToLowerCase($3);
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'NOTIN' '(' wordpat ',' forwardExpr ')'   transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.TagNotContainsTerm;
                                                            self.word := StringLib.StringToLowerCase($3);
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'SAME' '(' forwardExpr ',' forwardExpr ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.SameContainer;
                                                            self.numInputs := 2;
                                                            self := []
                                                        )
                                                    )
                                                )
    | 'P' '(' forwardExpr ')'                   transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.TagContainsSearch;
                                                            self.word := 'p';
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'S' '(' forwardExpr ')'                   transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.TagContainsSearch;
                                                            self.word := 's';
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'AT' '(' forwardExpr ',' number ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.PositionFilter;
                                                            self.seekWpos := (integer)$5;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'NOTAT' '(' forwardExpr ',' number ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.PositionNotFilter;
                                                            self.seekWpos := (integer)$5;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    //Useful for testing leaks on early termination
    | 'FIRST' '(' forwardExpr ',' number ')'    transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ChooseRange;
                                                            self.minMatches := 1;
                                                            self.maxMatches := (integer)$5;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    | 'RANGE' '(' forwardExpr ',' number ',' number ')' transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $3.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ChooseRange;
                                                            self.minMatches := (integer)$5;
                                                            self.maxMatches := (integer)$7;
                                                            self.numInputs := 1;
                                                            self := [];
                                                        )
                                                    )
                                                )
    //Internal - purely for testing the underlying functionality
    | '_ATLEASTIN_' '(' number ',' forwardExpr ',' number ')'
                                                transform(productionRecord,
                                                    self.termCount := 1;
                                                    self.actions := $5.actions + row(
                                                        transform(searchParseRecord,
                                                            self.action := actionEnum.ContainedAtLeast;
                                                            self.minMatches := (integer)$3;
                                                            self.numInputs := 1;
                                                            self.termsToProcess := dataset([createTerm((integer)$7)]);
                                                            self := [];
                                                        )
                                                    )
                                                )
    ;



PRULE expr
    := term1                                    : define ('ExpressionRule')
    ;

infile := dataset(row(transform({ string line{maxlength(1023)} }, self.line := queryText)));

resultsRecord := record
dataset(searchParseRecord) actions{maxcount(MaxActions)};
        end;


resultsRecord extractResults(dataset(searchParseRecord) actions) :=
        TRANSFORM
            SELF.actions := actions;
        END;

p1 := PARSE(infile,line,expr,extractResults($1.actions),first,whole,skip(ws),nocase,parse);

pnorm := normalize(p1, left.actions, transform(right));

//Now need to associate sequence numbers, and correctly set them up.
stageStackRecord := record
    stageType prevStage;
    dataset(stageRecord) stageStack{maxcount(MaxActions)};
end;

nullStack := row(transform(stageStackRecord, self := []));

assignStages(searchParseRecord l, stageStackRecord r) := module

    shared stageType thisStage := r.prevStage + 1;
    shared stageType maxStage := count(r.stageStack);
    shared stageType minStage := maxStage+1-l.numInputs;
    shared thisInputs := r.stageStack[minStage..maxStage];

    export searchParseRecord nextRow := transform
        self.stage := thisStage;
        self.term := thisStage;
        self.inputs := thisInputs;
        self := l;
    end;

    export stageStackRecord nextStack := transform
        self.prevStage := thisStage;
        self.stageStack := r.stageStack[1..maxStage-l.numInputs] + row(createStage(thisStage));
    end;
end;


sequenced := process(pnorm, nullStack, assignStages(left, right).nextRow, assignStages(left, right).nextStack);
return project(sequenced, transform(searchRecord, self := left));

end;

//Calculate the maximum number of words in phrase each operator could have as it's children (for use in proximity)
//easier to process since the graph is stored in reverse polish order
doCalculateMaxWip(dataset(searchRecord) input) := function

    stageStackRecord := record
        dataset(wipRecord) wipStack{maxcount(MaxActions)};
    end;

    nullStack := row(transform(stageStackRecord, self := []));

    assignStageWip(searchRecord l, stageStackRecord r) := module

        shared numInputs := count(l.inputs);
        shared stageType maxStage := count(r.wipStack);
        shared stageType minStage := maxStage+1-numInputs;

        shared maxLeftWip := r.wipStack[minStage].wip;
        shared maxRightWip := IF(numInputs > 1, r.wipStack[maxStage].wip, 0);
        shared maxChildWip := max(r.wipStack[minStage..maxStage], wip);
        shared sumMaxChildWip := sum(r.wipStack[minStage..maxStage], wip);

        shared thisMaxWip := case(l.action,
                actionEnum.ReadWord=>MaxWipWordOrAlias,
                actionEnum.AndTerms=>maxChildWip,
                actionEnum.OrTerms=>maxChildWip,
                actionEnum.AndNotTerms=>maxLeftWip,
                actionEnum.ButNotTerms=>maxLeftWip,
                actionEnum.ButNotJoinTerms=>maxLeftWip,
                actionEnum.PhraseAnd=>sumMaxChildWip,
                actionEnum.Phrase1To5And=>sumMaxChildWip,
                actionEnum.ProximityAnd=>MAX(l.maxDistanceRightBeforeLeft,l.maxDistanceRightAfterLeft,0) + sumMaxChildWip,
                actionEnum.OverlapProximityAnd=>sumMaxChildWip,
                actionEnum.MofNTerms=>maxChildWip,
                actionEnum.TagContainsTerm=>MaxWipTagContents,
                actionEnum.TagContainsSearch=>MaxWipTagContents,
                maxChildWip);


        export searchRecord nextRow := transform
            self.maxWip := thisMaxWip;
            self.maxWipLeft := maxLeftWip;
            self.maxWipRight := maxRightWip;
            self.maxWipChild := maxChildWip;
            self := l;
        end;

        export stageStackRecord nextStack := transform
            self.wipStack := r.wipStack[1..maxStage-numInputs] + row(transform(wipRecord, self.wip := thisMaxWip;));
        end;
    end;

    return process(input, nullStack, assignStageWip(left, right).nextRow, assignStageWip(left, right).nextStack);
end;

renumberRecord := RECORD
    stageType prevStage;
    dataset(stageMapRecord) map{maxcount(maxStages)};
END;
nullRenumber := row(transform(renumberRecord, self := []));

deleteExpandStages(input, expandTransform, result) := MACRO
    #uniquename (renumberStages)
    #uniquename (stagea)
    #uniquename (stageb)

    %renumberStages%(recordof(input) l, renumberRecord r) := module
        shared prevStage := r.prevStage;
        shared nextStage := prevStage + l.numStages;
        export recordof(input) nextRow := transform
            SELF.stage := prevStage + 1;
            SELF.inputs := project(l.inputs, createStage(r.map(from = left.stage)[1].to));
            SELF := l;
        end;
        export renumberRecord nextRight := transform
            SELF.prevStage := nextStage;
            SELF.map := r.map + row(transform(stageMapRecord, self.from := l.stage; self.to := nextStage));
        end;
    end;

    %stagea% := process(input, nullRenumber, %renumberStages%(left, right).nextRow, %renumberStages%(left, right).nextRight);
    %stageb% := %stagea%(numStages != 0);
    result := normalize(%stageb%, left.numStages, expandTransform(LEFT, COUNTER))
ENDMACRO;



// 1) IN(IN(ATLEAST(n, x))  -> IN(ContainedAtLeast(IN(x))
//    or more complicated....
//    IN:X(ATLEAST(2, x) AND ATLEAST(3, y))
//    ->_ATLEAST_(2, [term:x], _ATLEAST_(3, [term:y], IN:X(x AND y)))
//    The contained atleast is swapped with a surrounding IN, and converted to a contained at least
//
//    Algorithm:
//    a) Gather a list of terms that each atleast works on, and annotate each IN with a list of atleasts.
//    b) Invert the list, and tag any atleasts that are going to be moved.
//    c) Resort the list, remove any atleasts being moved, and wrap each IN with each of the atleasts being moved.

transformAtLeast(dataset(searchRecord) parsed) := function

    atleastRecord := RECORD
        termType atleastTerm;
        matchCountType minMatches;
        dataset(termRecord) terms{maxcount(MaxTerms)};
    END;

    atleastRecord createAtleast(searchRecord l, dataset(termRecord) terms) := transform
        SELF.atleastTerm := l.term;
        SELF.minMatches := l.minMatches;
        SELF.terms := terms;
    END;

    //Project to the structure that allows processing.
    processRecord := RECORD(searchRecord)
        termType numStages;
        dataset(atleastRecord) moved{maxcount(MaxTerms)};
    END;
    stage0 := project(parsed, transform(processRecord, self := left; self := []));

    //Gather a list of inut and output terms, and a list of atleasts that need moving.
    activeRecord := RECORD
        stageType stage;
        dataset(termRecord) outputTerms{maxcount(MaxTerms)};
        dataset(atleastRecord) activeAtleast{maxcount(MaxTerms)};
    END;
    stage1Record := RECORD
        dataset(activeRecord) mapping;
    END;
    doStage1(processRecord l, stage1Record r) := module
        shared inputTerms := r.mapping(stage in set(l.inputs, stage)).outputTerms;
        shared inputAtleast := r.mapping(stage in set(l.inputs, stage)).activeAtleast;
        shared outputTerms := IF(hasSingleRowPerMatch(l.action), dataset([createTerm(l.term)]), inputTerms);
        shared outputAtleast :=
            MAP(l.action = actionEnum.GlobalAtLeast=>inputAtleast + row(createAtleast(l, inputTerms)),
                l.action <> actionEnum.TagContainsSearch=>inputAtleast);

        export processRecord nextRow := transform
            SELF.moved := IF(l.action = actionEnum.TagContainsSearch, inputAtLeast);
#if (INCLUDE_DEBUG_INFO)
            SELF.debug := trim(l.debug) + '[' +
                    (string)COUNT(inputTerms) + ':' +
                    (string)COUNT(inputAtleast) + ':' +
                    (string)COUNT(outputTerms) + ':' +
                    (string)COUNT(outputAtLeast) + ':' +
                    (string)COUNT(IF(l.action = actionEnum.TagContainsSearch, inputAtLeast)) + ':' +
                    ']';
#end
            SELF := l;
        end;
        export stage1Record nextRight := transform
            SELF.mapping := r.mapping + row(transform(activeRecord, self.stage := l.stage; self.outputTerms := outputTerms; self.activeAtleast := outputAtleast));
        end;
    end;
    nullStage1 := row(transform(stage1Record, self := []));
    stage1 := process(stage0, nullStage1, doStage1(left, right).nextRow, doStage1(left, right).nextRight);
    invertedStage1 := sort(stage1, -stage);

    //Now build up a list of stages that are contained within a tag, and if an atleast is within a tag then mark it for removal
    //Build up a list of inputs which need to be wrapped with inEnsure the at least is only tagged onto the outer IN(), and set the minimum matches to 0 for the inner atleast()
    stage2Record := RECORD
        dataset(stageRecord) mapping{maxcount(MaxStages)};
    END;
    doStage2(processRecord l, stage2Record r) := module
        shared removeThisStage := (l.action = actionEnum.GlobalAtLeast and exists(r.mapping(stage = l.stage)));
        shared numStages := IF(removeThisStage,0,1 + count(l.moved));
        export processRecord nextRow := transform
            SELF.numStages := numStages;
            SELF := l;
        end;
        export stage2Record nextRight := transform
            SELF.mapping := r.mapping + IF(l.action = actionEnum.TagContainsSearch or exists(r.mapping(stage = l.stage)), l.inputs);
        end;
    end;
    nullStage2 := row(transform(stage2Record, self := []));
    stage2 := process(invertedStage1, nullStage2, doStage2(left, right).nextRow, doStage2(left, right).nextRight);
    revertedStage2 := sort(stage2, stage);

    //Remove atleast inside container, add them back around the tag, and renumber stages.
    processRecord duplicateAtLeast(processRecord l, unsigned c) := TRANSFORM
        SELF.stage := l.stage + (c - 1);
        SELF.inputs := IF(c>1, dataset([createStage(l.stage + c - 2)]), l.inputs);
        SELF.action := IF(c>1, actionEnum.ContainedAtLeast, l.action);
        SELF.minMatches := IF(c>1, l.moved[c-1].minMatches, l.minMatches);
        SELF.termsToProcess := IF(c>1, l.moved[c-1].terms, l.termsToProcess);
        SELF := l;
    END;
    deleteExpandStages(revertedStage2, duplicateAtLeast, stage3c);

    return project(stage3c, transform(searchRecord, self := left));
end;



// 2) NOT IN:X((A OR B) AND PHRASE(c, D)) -> OR(NOT IN:X(A),NOT IN:X(B)) AND NOT IN:X(PHRASE(C,D))
//
//    NOT IN (A AND B) means same as NOT IN (A) AND NOT IN (B)
//    NOT IN (A OR B) means same as NOT IN (A) OR NOT IN (B)
//
//    Need to move the NOT IN() operator down, so it surrounds items that are guaranteed to generate a single item

transformNotIn(dataset(searchRecord) input) := function

    //Project to the structure that allows processing.
    processRecord := RECORD(searchRecord)
        termType numStages;
        boolean singleRowPerMatch;
        boolean inputsSingleRowPerMatch;
        wordType newContainer;
        termType newTerm;
    END;
    stage0 := project(input, transform(processRecord, self := left; self := []));

    //Annotate all nodes with whether or not they are single valued.  (So simple OR phrase is noted as single)
    //the atleast id/min of any ATLEASTs they directly contain
    stage1Record := RECORD
        dataset(booleanRecord) isSingleMap;
    END;
    doStage1(processRecord l, stage1Record r) := module
        shared inputsSingleValued := not exists(l.inputs(not r.isSingleMap[l.inputs.stage].value));
        shared isSingleValued := IF(inheritsSingleRowPerMatch(l.action), inputsSingleValued, hasSingleRowPerMatch(l.action));
        export processRecord nextRow := transform
            SELF.singleRowPerMatch := isSingleValued;
            SELF.inputsSingleRowPerMatch := inputsSingleValued;
#if (INCLUDE_DEBUG_INFO)
            SELF.debug := trim(l.debug) + '[' + TF(isSingleValued) + TF(inputsSingleValued) + ']';
#end
            SELF := l;
        end;
        export stage1Record nextRight := transform
            SELF.isSingleMap := r.isSingleMap + row(transform(booleanRecord, self.value := isSingleValued));
        end;
    end;
    nullStage1 := row(transform(stage1Record, self := []));
    stage1 := process(stage0, nullStage1, doStage1(left, right).nextRow, doStage1(left, right).nextRight);
    invertedStage1 := sort(stage1, -stage);

    //Build up a list of inputs which need to be wrapped with inEnsure the at least is only tagged onto the outer IN(), and set the minimum matches to 0 for the inner atleast()
    mapRecord := RECORD
        stageType stage;
        wordType container;
        termType term;
    END;
    stage2Record := RECORD
        dataset(mapRecord) map;
    END;
    doStage2(processRecord l, stage2Record r) := module
        shared newContainer := r.map(stage = l.stage)[1].container;
        shared newTerm := r.map(stage = l.stage)[1].term;
        shared numStages :=
                    MAP(l.singleRowPerMatch and newContainer <> ''=>2,
                        l.action = actionEnum.TagNotContainsTerm and not l.singleRowPerMatch=>0,
                        1);
        export processRecord nextRow := transform
            SELF.newContainer := newContainer;
            SELF.newTerm := newTerm;
            SELF.numStages := numStages;
#if (INCLUDE_DEBUG_INFO)
            SELF.debug := trim(l.debug) + '[' + newContainer + ']';
#end
            SELF := l;
        end;
        export stage2Record nextRight := transform
            SELF.map := r.map + MAP(l.action = actionEnum.TagNotContainsTerm and not l.inputsSingleRowPerMatch=>
                                        PROJECT(l.inputs, transform(mapRecord, SELF.stage := LEFT.stage; SELF.container := l.word; SELF.term := l.term)),
                                    not l.singleRowPerMatch and (newContainer <> '')=>
                                        PROJECT(l.inputs, transform(mapRecord, SELF.stage := LEFT.stage; SELF.container := newContainer; SELF.term := newTerm)));
        end;
    end;
    nullStage2 := row(transform(stage2Record, self := []));
    stage2 := process(invertedStage1, nullStage2, doStage2(left, right).nextRow, doStage2(left, right).nextRight);
    revertedStage2 := sort(stage2, stage);

    //Map the operators within the container, add map the outer TagContainsSearch to a RollupContainer
    processRecord duplicateContainer(processRecord l, unsigned c) := TRANSFORM
        SELF.stage := l.stage + (c - 1);
        SELF.inputs := IF(c=2, dataset([createStage(l.stage)]), l.inputs);
        SELF.action := IF(c=2, actionEnum.TagNotContainsTerm, l.action);
        SELF.word := IF(c=2, l.newContainer, l.word);
        SELF.term := IF(c=2, l.newTerm, l.term);
        SELF := l;
    END;
    deleteExpandStages(revertedStage2, duplicateContainer, stage3c);

    result := project(stage3c, transform(searchRecord, self := left));
    //RETURN IF (exists(input(action = actionEnum.TagContainsSearch)), result, input);
    RETURN result;
end;

// 3) IN:X(OR((A OR B) AND PHRASE(c, D)) -> SAME(OR(IN:X(A),IN:X(B)), IN:X(PHRASE(C,D))
//
//    Need to move the IN() operator down, so it surrounds items that are guaranteed to generate a single item
//    per match, and then convert intervening operators as follows
//    AND->SAMEWORD, OR->OR, ANDNOT-> NOTSAMEWORD, MOFN->MOFNWORD, RANK->RANKWORD
//    the in is moved down to all the operators below that generate a single row per match.
//
//    Note, PHRASE and PROXIMITY create single items, so they will work as expected.
//    (a or b) BUTNOT (c) may have issues

transformIn(dataset(searchRecord) input) := function

    //Project to the structure that allows processing.
    processRecord := RECORD(searchRecord)
        termType numStages;
        boolean singleRowPerMatch;
        boolean inputsSingleRowPerMatch;
        wordType newContainer;
        termType newTerm;
    END;
    stage0 := project(input, transform(processRecord, self := left; self := []));

    //Annotate all nodes with whether or not they are single valued.  (So simple OR phrase is noted as single)
    //the atleast id/min of any ATLEASTs they directly contain
    stage1Record := RECORD
        dataset(booleanRecord) isSingleMap;
    END;
    doStage1(processRecord l, stage1Record r) := module
        shared inputsSingleValued := not exists(l.inputs(not r.isSingleMap[l.inputs.stage].value));
        shared isSingleValued := IF(inheritsSingleRowPerMatch(l.action), inputsSingleValued, hasSingleRowPerMatch(l.action));
        export processRecord nextRow := transform
            SELF.singleRowPerMatch := isSingleValued;
            SELF.inputsSingleRowPerMatch := inputsSingleValued;
#if (INCLUDE_DEBUG_INFO)
            SELF.debug := trim(l.debug) + '[' + TF(isSingleValued) + TF(inputsSingleValued) + ']';
#end
            SELF := l;
        end;
        export stage1Record nextRight := transform
            SELF.isSingleMap := r.isSingleMap + row(transform(booleanRecord, self.value := isSingleValued));
        end;
    end;
    nullStage1 := row(transform(stage1Record, self := []));
    stage1 := process(stage0, nullStage1, doStage1(left, right).nextRow, doStage1(left, right).nextRight);
    invertedStage1 := sort(stage1, -stage);

    //Build up a list of inputs which need to be wrapped with inEnsure the at least is only tagged onto the outer IN(), and set the minimum matches to 0 for the inner atleast()
    mapRecord := RECORD
        stageType stage;
        wordType container;
        termType term;
    END;
    stage2Record := RECORD
        dataset(mapRecord) map;
    END;
    doStage2(processRecord l, stage2Record r) := module
        shared newContainer := r.map(stage = l.stage)[1].container;
        shared newTerm := r.map(stage = l.stage)[1].term;
        shared numStages := IF(l.singleRowPerMatch and newContainer <> '', 2, 1);
        export processRecord nextRow := transform
            SELF.newContainer := newContainer;
            SELF.newTerm := newTerm;
            SELF.numStages := numStages;
#if (INCLUDE_DEBUG_INFO)
            SELF.debug := trim(l.debug) + '[' + newContainer + ']';
#end
            SELF := l;
        end;
        export stage2Record nextRight := transform
            SELF.map := r.map + MAP(l.action = actionEnum.TagContainsSearch and not l.inputsSingleRowPerMatch=>
                                        PROJECT(l.inputs, transform(mapRecord, SELF.stage := LEFT.stage; SELF.container := l.word; SELF.term := l.term)),
                                    not l.singleRowPerMatch and (newContainer <> '')=>
                                        PROJECT(l.inputs, transform(mapRecord, SELF.stage := LEFT.stage; SELF.container := newContainer; SELF.term := newTerm)));
        end;
    end;
    nullStage2 := row(transform(stage2Record, self := []));
    stage2 := process(invertedStage1, nullStage2, doStage2(left, right).nextRow, doStage2(left, right).nextRight);
    revertedStage2 := sort(stage2, stage);

    //Map the operators within the container, add map the outer TagContainsSearch to a RollupContainer
    processRecord duplicateContainer(processRecord l, unsigned c) := TRANSFORM
        actionEnum mappedAction :=
            CASE(l.action,
                 actionEnum.AndTerms        => IF(l.newContainer <> '', actionEnum.SameContainer, l.action),
                 actionEnum.AndNotTerms     => IF(l.newContainer <> '', actionEnum.NotSameContainer, l.action),
                 actionEnum.MofNTerms       => IF(l.newContainer <> '', actionEnum.MofNContainer, l.action),
                 actionEnum.RankMergeTerms  => IF(l.newContainer <> '', actionEnum.RankContainer, l.action),
                 actionEnum.TagContainsSearch => IF(l.inputsSingleRowPerMatch, actionEnum.TagContainsSearch, actionEnum.rollupContainer),
                 l.action);


        SELF.stage := l.stage + (c - 1);
        SELF.inputs := IF(c=2, dataset([createStage(l.stage)]), l.inputs);
        SELF.action := IF(c=2, actionEnum.TagContainsTerm, mappedAction);
        SELF.word := IF(c=2, l.newContainer, l.word);
        SELF.term := IF(c=2, l.newTerm, l.term);
        SELF := l;
    END;
    deleteExpandStages(revertedStage2, duplicateContainer, stage3c);

    result := project(stage3c, transform(searchRecord, self := left));
    //RETURN IF (exists(input(action = actionEnum.TagContainsSearch)), result, input);
    RETURN result;
end;


applySearchTransformations(dataset(searchRecord) input) := FUNCTION
    processed1 := transformAtLeast(input);
    processed2 := transformNotIn(processed1);
    processed3 := transformIn(processed2);
    processed4 := doCalculateMaxWip(processed3);
    RETURN processed4;
END;

queryProcessor(dataset(TS.wordIndexRecord) wordIndex, string query, boolean useLocal, unsigned4 internalFlags) := module//,library('TextSearch',1,0)
export string queryText := query;
export request := parseQuery(query);
export processed := applySearchTransformations(request);
export result := SearchExecutor(wordIndex, internalFlags).doExecuteQuery(processed, useLocal);
    end;


MaxResults := 10000;

publicExports := MODULE

    EXPORT getWordIndex(boolean multiPart, boolean useLocal) := FUNCTION
        Files := Setup.Files(multiPart, useLocal);
        RETURN Files.getWordIndex();
    END;
    
    EXPORT queryInputRecord := { string query{maxlength(2048)}; };

    EXPORT processedRecord := record(queryInputRecord)
        dataset(searchRecord) request{maxcount(MaxActions)};
        dataset(simpleUserOutputRecord) result{maxcount(MaxResults)};
    END;
    
    EXPORT GetSearchExecutor(dataset(TS.wordIndexRecord) wordIndex, unsigned4 internalFlags = 0) := SearchExecutor(wordIndex, internalFlags);
    
    EXPORT processedRecord doBatchExecute(dataset(TS.wordIndexRecord) wordIndex, queryInputRecord l, boolean useLocal, unsigned4 internalFlags=0) := transform
        processed := queryProcessor(wordIndex, l.query, useLocal, internalFlags);
        self.request := processed.processed;
        self.result := choosen(processed.result, MaxResults);
        self := l;
    end;


    EXPORT doSingleExecute(dataset(TS.wordIndexRecord) wordIndex, string queryText, boolean useLocal, unsigned4 internalFlags=0) := function
        request := parseQuery(queryText);
        result := SearchExecutor(wordIndex, internalFlags).doExecuteQuery(request, useLocal);
        return result;
    end;

    EXPORT executeBatchAgainstWordIndex(DATASET(queryInputRecord) queries, boolean useLocal, boolean multiPart, unsigned4 internalFlags=0) := FUNCTION
        wordIndex := getWordIndex(multiPart, useLocal);
        p := project(nofold(queries), doBatchExecute(wordIndex, LEFT, useLocal, internalFlags));
        RETURN p;
    END;

END;

   RETURN publicExports;

END;
