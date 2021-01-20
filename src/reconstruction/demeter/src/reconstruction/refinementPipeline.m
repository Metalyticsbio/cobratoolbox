function [refinedModel, summary] = refinementPipeline(model, microbeID, infoFilePath, inputDataFolder)
% This function runs the semi-automatic refinement pipeline on a draft
% reconstruction generated by the KBase pipeline or a previously refined 
% reconstruction.
%
% USAGE:
%
%    [refinedModel, summary] = refinementPipeline(modelIn, microbeID, infoFilePath, inputDataFolder)
%
% INPUTS
% model             COBRA model structure to refine
% microbeID         ID of the reconstructed microbe that serves as the 
%                   reconstruction name and to identify it in input tables
% infoFilePath      File with information on reconstructions to refine
% inputDataFolder   Folder with input tables with experimental data and
%                   databases that inform the refinement process
% OUTPUT
% refinedModel      COBRA model structure refined through AGORA pipeline
%
% .. Authors:
%       - Almut Heinken and Stefania Magnusdottir, 2016-2020

if ~isempty(infoFilePath)
    infoFile = readtable(infoFilePath, 'ReadVariableNames', false);
    infoFile = table2cell(infoFile);
    if ~any(strcmp(infoFile(:,1),microbeID))
        warning('No organism information provided. The pipeline will not be able to curate the reconstruction based on gram status.')
    end
else
    infoFile = readtable('AGORA2_infoFile.xlsx', 'ReadVariableNames', false);
    infoFile = table2cell(infoFile);
    if ~any(strcmp(infoFile(:,1),microbeID))
        warning('No organism information provided. The pipeline will not be able to curate the reconstruction based on gram status.')
    end
end

tol=0.0000001;

% implement Western diet
WesternDiet = readtable('WesternDietAGORA2.txt', 'Delimiter', 'tab');
WesternDiet=table2cell(WesternDiet);
WesternDiet=cellstr(string(WesternDiet));

% Load reaction and metabolite database
metaboliteDatabase = readtable('MetaboliteDatabase.txt', 'Delimiter', 'tab','TreatAsEmpty',['UND. -60001','UND. -2011','UND. -62011'], 'ReadVariableNames', false);
metaboliteDatabase=table2cell(metaboliteDatabase);
database.metabolites=metaboliteDatabase;
for i=1:size(database.metabolites,1)
    database.metabolites{i,5}=num2str(database.metabolites{i,5});
    database.metabolites{i,7}=num2str(database.metabolites{i,7});
    database.metabolites{i,8}=num2str(database.metabolites{i,8});
end
reactionDatabase = readtable('ReactionDatabase.txt', 'Delimiter', 'tab','TreatAsEmpty',['UND. -60001','UND. -2011','UND. -62011'], 'ReadVariableNames', false);
reactionDatabase=table2cell(reactionDatabase);
database.reactions=reactionDatabase;

% convert data types if necessary
database.metabolites(:,7)=strrep(database.metabolites(:,7),'NaN','');
database.metabolites(:,8)=strrep(database.metabolites(:,8),'NaN','');

%% special case: two biomass reactions in model (bug in KBase?)
if length(intersect(model.rxns,{'bio1','bio2'}))==2
    model=removeRxns(model,'bio2');
end

biomassReaction=model.rxns{strncmp(model.rxns,'bio',3)};
if isempty(biomassReaction)
    error('Biomass objective function could not be found in the model!')
end

%% Translate to VMH if it is an untranslated KBase model
[model,notInTableRxns,notInTableMets] = translateKBaseModel2VMHModel(model,biomassReaction,database);
if ~isempty(notInTableRxns)
    summary.('untranslatedRxns') = notInTableRxns;
end
if ~isempty(notInTableMets)
    summary.('untranslatedMets') = notInTableMets;
end

%% add some reactions that need to be in every reconstruction
essentialRxns={'DM_atp_c_','sink_PGPm1[c]','EX_nh4(e)','NH4tb','Kt1r'};
if ~find(strcmp(model.mets,'pi[e]'))
    essentialRxns=horzcat(essentialRxns,{'EX_pi(e)','PIabc'});
end

for i=1:length(essentialRxns)
    model = addReaction(model, essentialRxns{i}, 'reactionFormula', database.reactions{find(ismember(database.reactions(:, 1), essentialRxns{i})), 3}, 'geneRule', 'essentialGapfill');
end

%% Refinement steps
% The following sections include the various refinement steps of the pipeline.
% The different functions may have to be run multiple times as the solutions and
% reactions added in one section may influence the result of a previously run
% section. It is possible that some issues cannot be resolved using the following
% functions as the functions have been developed based on issues that arose during
% refinement of the AGORA 1.0 reconstructions [REF]. In those cases, it is necessary
% to manually identify the problems and the possible solutions.
%
% _*IMPORTANT:* Note that reactions added in a refinement step may influence
% the results of other steps. It is therefore important to run each refinement
% step more than once in order to make sure that all functionalities are captured.
% This is especially important for steps testing for reconstruction quality._

%% Rebuild biomass objective function for organisms that do not have cell wall
[model,removedBioComp,addedReactionsBiomass]=rebuildBiomassReaction(model,microbeID,biomassReaction,database,infoFile);
summary.('removedBioComp') = removedBioComp;
summary.('addedReactionsBiomass') = addedReactionsBiomass;

%% Refine genome annotations
[model,addAnnRxns,updateGPRCnt]=refineGenomeAnnotation(model,microbeID,database,inputDataFolder);
summary.('addAnnRxns') = addAnnRxns;
summary.('updateGPRCnt') = updateGPRCnt;

%% perform refinement based on experimental data
[model,summary] = performDataDrivenRefinement(model, microbeID, database, inputDataFolder, summary);

%% Reconnect blocked reactions and perform gapfilling to enable growth
% connect speciifc pathways
[resolveBlocked,model]=connectRxnGapfilling(model,database);
summary.('resolveBlocked') = resolveBlocked;

% run gapfilling tools to enable biomass production
[model,gapfilledRxns] = runGapfillingTools(model,biomassReaction,'max',database);
summary.('gapfilledRxns') = gapfilledRxns;

%% Anaerobic growth-may need to run twice

[model,oxGapfillRxns,anaerGrowthOK] = anaerobicGrowthGapfill(model, biomassReaction, database);
summary.('anaerobicGapfillRxns') = oxGapfillRxns;
summary.('anaerobicGrowthOK') = anaerGrowthOK;
if ~anaerGrowthOK
    [model,oxGapfillRxns,anaerGrowthOK] = anaerobicGrowthGapfill(model, biomassReaction, database);
end
summary.('anaerobicGapfillRxns') = union(summary.('anaerobicGapfillRxns'),oxGapfillRxns);
summary.('anaerobicGrowthOK') = anaerGrowthOK;

%% gapfilling for growth on Western diet
[AerobicGrowth, AnaerobicGrowth] = testGrowth(model, biomassReaction);
if AnaerobicGrowth(1,2) < tol
    % apply Western diet
    model = useDiet(model,WesternDiet);
    % run gapfilling tools to enable biomass production if no growth on
    % Western diet
    [model,gapfilledRxns] = runGapfillingTools(model,biomassReaction,'max',database);
    summary.('gapfilledRxns') = union(summary.('gapfilledRxns'),gapfilledRxns);
end

%% Stoichiometrically balanced cycles
[model, deletedRxns, addedRxns] = removeFutileCycles(model, biomassReaction, database);
summary.('balancedCycle_addedRxns') = unique(addedRxns);
summary.('balancedCycle_deletedRxns') = unique(deletedRxns);

%% Remove unneeded reactions
% Delete gap-filled reactions by KBase/ ModelSEED that are no longer needed
[model,deletedSEEDRxns]=deleteSeedGapfilledReactions(model,biomassReaction);
summary.('deletedSEEDRxns')=deletedSEEDRxns;

%% change back to unlimited medium
% list exchange reactions
exchanges = model.rxns(strncmp('EX_', model.rxns, 3));
% open all exchanges
model = changeRxnBounds(model, exchanges, -1000, 'l');
model = changeRxnBounds(model, exchanges, 1000, 'u');

%% Delete unused reactions that are leftovers from KBase pipeline
% Delete transporters without exchanges
[model, transportersWithoutExchanges] = findTransportersWithoutExchanges(model);
summary.('transportersWithoutExchanges') = transportersWithoutExchanges;

% Delete unused exchange reactions
[model, unusedExchanges] = findUnusedExchangeReactions(model);
summary.('unusedExchanges') = unusedExchanges;

%% Some models cannot grow afterwards
% If model is still unable to grow
FBA=optimizeCbModel(model,'max');
if FBA.f<tol
    % run gapfilling tools to enable biomass production
    [model,gapfilledRxns] = runGapfillingTools(model,biomassReaction,'max',database);
    summary.('gapfilledRxns') = union(summary.('gapfilledRxns'),gapfilledRxns);
end

% in rare cases: gapfilling for anaerobic growth or growth on Western diet still needed
for i=1:2
    [AerobicGrowth, AnaerobicGrowth] = testGrowth(model, biomassReaction);
    if AnaerobicGrowth(1,2) < tol
        % apply Western diet
        model = useDiet(model,WesternDiet);
        % run gapfilling tools to enable biomass production
        [model,gapfilledRxns] = runGapfillingTools(model,biomassReaction,'max',database);
        summary.('gapfilledRxns') = union(summary.('gapfilledRxns'),gapfilledRxns);
    end
    
    if AnaerobicGrowth(1,1) < tol
        [model,oxGapfillRxns,anaerGrowthOK] = anaerobicGrowthGapfill(model, biomassReaction, database);
        summary.('anaerobicGapfillRxns') = union(summary.('anaerobicGapfillRxns'),oxGapfillRxns);
        summary.('anaerobicGrowthOK') = anaerGrowthOK;
    end
end

%% Nutrient requirements
% Needs to be done after deleting Seed-gapfilled reactions but before removing duplicate reactions
% Needs to be run repeatedly for some models
summary.('addedMismatchRxns')={};
summary.('deletedMismatchRxns')={};
for i = 1:6
    [growsOnDefinedMedium,essentialExchanges] = testGrowthOnDefinedMedia(model, microbeID, biomassReaction);
    if growsOnDefinedMedium==0
        [model, addedMismatchRxns, deletedMismatchRxns] = curateGrowthRequirements(model, microbeID, biomassReaction, database, inputDataFolder);
        summary.('addedMismatchRxns') = union(summary.('addedMismatchRxns'),addedMismatchRxns);
        summary.('deletedMismatchRxns') = union(summary.('deletedMismatchRxns'),deletedMismatchRxns);
    else
        break
    end
    % relax enforced uptake of vitamins-causes infeasibility problems
    relaxConstraints=model.rxns(find(model.lb>0));
    model=changeRxnBounds(model,relaxConstraints,0,'l');
end
summary.('definedMediumGrowth')=growsOnDefinedMedium;

%% remove duplicate reactions
% Will remove reversible reactions of which an irreversible version is also
% there but keep the irreversible version.
modelTest = useDiet(model,WesternDiet);
[modelRD, removedRxnInd, keptRxnInd] = checkDuplicateRxn(modelTest);
% test if the model can still grow
FBA=optimizeCbModel(modelRD,'max');
if FBA.f > tol
    summary.('deletedDuplicateRxns') = model.rxns(removedRxnInd);
    model=modelRD;
else
    modelTest=model;
        toRM={};
        for j=1:length(removedRxnInd)
            modelRD=removeRxns(modelTest,model.rxns(removedRxnInd(j)));
            modelRD = useDiet(modelRD,WesternDiet);
            FBA=optimizeCbModel(modelRD,'max');
            if FBA.f > tol
                modelTest=removeRxns(modelTest, model.rxns{removedRxnInd(j)});
                toRM{j}=model.rxns{removedRxnInd(j)};
            else
                modelTest=removeRxns(modelTest, model.rxns{keptRxnInd(j)});
                toRM{j}=model.rxns{keptRxnInd(j)};
            end
        end
    summary.('deletedDuplicateRxns') = toRM;
    model=removeRxns(model,toRM);
end

%% remove reactions that were present in draft reconstructions but should not be present according to comparative genomics
[model,rmUnannRxns]=removeUnannotatedReactions(model,microbeID,biomassReaction,growsOnDefinedMedium,inputDataFolder);
summary.('removedUnannotatedReactions') = rmUnannRxns;

%% double-check if gap-filled reactions are really needed anymore
% If growth on a defined medium was achieved, use the constrained model
[model,summary]=doubleCheckGapfilledReactions(model,summary,biomassReaction,microbeID,database,growsOnDefinedMedium, inputDataFolder);

%% Need to repeat experimental data gap-fill because some reactions may be removed now that were there before
% perform refinement based on experimental data
[model,summary] = performDataDrivenRefinement(model, microbeID, database, inputDataFolder,summary);

%% enable growth on defined medium if still needed
[growsOnDefinedMedium,constrainedModel] = testGrowthOnDefinedMedia(model, microbeID, biomassReaction);
if growsOnDefinedMedium==0
    [model, addedMismatchRxns, deletedMismatchRxns] = curateGrowthRequirements(model, microbeID, biomassReaction, database, inputDataFolder);
    summary.('addedMismatchRxns') = union(summary.('addedMismatchRxns'),addedMismatchRxns);
    summary.('deletedMismatchRxns') = union(summary.('deletedMismatchRxns'),deletedMismatchRxns);
    % relax enforced uptake of vitamins-causes infeasibility problems
    relaxConstraints=model.rxns(find(model.lb>0));
    model=changeRxnBounds(model,relaxConstraints,0,'l');
    [growsOnDefinedMedium,constrainedModel] = testGrowthOnDefinedMedia(model, microbeID, biomassReaction);
    if growsOnDefinedMedium
        summary.('definedMediumGrowth')=growsOnDefinedMedium;
    else
        % run gapfilling tools to enable biomass production on the defined
        % medium
        [model,gapfilledRxns] = runGapfillingTools(constrainedModel,biomassReaction,'max',database);
        summary.('definedMediumGrowth') = union(summary.('definedMediumGrowth'),gapfilledRxns);
    end
end

%% remove futile cycles if any remain
[atpFluxAerobic, atpFluxAnaerobic] = testATP(model);
if atpFluxAnaerobic>100
    % if models can grow on defined medium, this will be abolishd in some
    % cases -> need to use the constrained model as input
    [growsOnDefinedMedium,constrainedModel] = testGrowthOnDefinedMedia(model, microbeID, biomassReaction);
    if growsOnDefinedMedium==1
        [model, deletedRxns, addedRxns] = removeFutileCycles(model, biomassReaction, database,{},constrainedModel);
    else
        [model, deletedRxns, addedRxns] = removeFutileCycles(model, biomassReaction, database);
    end
    summary.('balancedCycle_addedRxns') = union(summary.('balancedCycle_addedRxns'),unique(addedRxns));
    summary.('balancedCycle_deletedRxns') = union(summary.('balancedCycle_deletedRxns'),unique(deletedRxns));
end

%% remove duplicate reactions-needs repetition for some microbes
% Will remove reversible reactions of which an irreversible version is also
% there but keep the irreversible version.
% use defined medium if possible, otherwise Western diet
if growsOnDefinedMedium==1
    [~,modelTest] = testGrowthOnDefinedMedia(model, microbeID, biomassReaction);
else
modelTest = useDiet(model,WesternDiet);
end
[modelRD, removedRxnInd, keptRxnInd] = checkDuplicateRxn(modelTest);
% test if the model can still grow
FBA=optimizeCbModel(modelRD,'max');
if FBA.f > tol
    summary.('deletedDuplicateRxns') = model.rxns(removedRxnInd);
    model=modelRD;
else
    for j=1:length(removedRxnInd)
        modelTest=removeRxns(model,model.rxns(removedRxnInd(j)));
        modelTest = useDiet(modelTest,WesternDiet);
        FBA=optimizeCbModel(modelTest,'max');
        if FBA.f > tol
            model =  removeRxns(model,model.rxns{removedRxnInd(j)});
            summary.('deletedDuplicateRxns') = union(summary.('deletedDuplicateRxns'),model.rxns{removedRxnInd(j)});
        else
            summary.('deletedDuplicateRxns') = union(summary.('deletedDuplicateRxns'),model.rxns{keptRxnInd(j)});
        end
    end
end

%% Delete sink for petidoglycan if not needed
modelTest = removeRxns(model, 'sink_PGPm1[c]');
FBA = optimizeCbModel(modelTest, 'max');
if FBA.f>tol
    model= modelTest;
end

%% addd refinement descriptions to model.comments field
model = addRefinementComments(model);

%% rebuild model
[model] = rebuildModel(model,database);

%% constrain sink reactions
model.lb(find(strncmp(model.rxns,'sink_',5)))=-1;

%% add periplasmatic space
if ~isempty(infoFilePath)
    if ~any(strcmp(infoFile(:,1),microbeID))
        model = createPeriplasmaticSpace(model,microbeID,infoFile);
    end
end

%% end the pipeline
refinedModel = model;

end
