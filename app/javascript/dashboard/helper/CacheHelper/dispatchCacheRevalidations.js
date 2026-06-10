import InboxesAPI from 'dashboard/api/inboxes';
import LabelsAPI from 'dashboard/api/labels';
import TeamsAPI from 'dashboard/api/teams';
import { cacheableModels } from './cacheableModels';

// model name → cache-enabled API client. Lives here rather than in
// cacheableModels to keep that module import-cycle-free: the API clients
// import DataManager, which imports cacheableModels.
const apiByModel = {
  inbox: InboxesAPI,
  label: LabelsAPI,
  team: TeamsAPI,
};

const revalidateModel = async (store, model, newKey) => {
  try {
    const api = apiByModel[model.name];
    if (await api.validateCacheKey(newKey)) return;

    const response = await api.refetchAndCommit(newKey);
    store.commit(model.setMutation, api.extractDataFromResponse(response));
  } catch {
    // Ignore error — a failed refetch leaves the painted data in place; the
    // next pushed key map retries.
  }
};

// The single freshness engine: given a pushed { model_name => key } map
// (RoomChannel transmits one on every (re)subscribe, the server broadcasts
// one on every change), diff each key against IDB and refetch mismatches.
export const dispatchCacheRevalidations = (store, keys = {}) =>
  Promise.all(
    cacheableModels
      .filter(model => keys[model.name] !== undefined)
      .map(model => revalidateModel(store, model, keys[model.name]))
  );
