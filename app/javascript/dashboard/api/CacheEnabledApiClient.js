/* global axios */
import { DataManager } from '../helper/CacheHelper/DataManager';
import ApiClient from './ApiClient';

class CacheEnabledApiClient extends ApiClient {
  constructor(resource, options = {}) {
    super(resource, options);
    // `cacheModel` is the Rails Model.name.underscore value — simultaneously
    // the server cache-key name and the IDB object-store name.
    this.cacheModelName = options.cacheModel;
    // inbox/label endpoints wrap collections in { payload }; the rest return
    // the bare array.
    this.payloadEnvelope = options.payloadEnvelope || false;
    this.dataManager = new DataManager(this.accountIdFromRoute);
  }

  get(cache = false) {
    if (cache) {
      return this.getFromCache();
    }

    return this.getFromNetwork();
  }

  getFromNetwork() {
    return axios.get(this.url);
  }

  extractDataFromResponse(response) {
    return this.payloadEnvelope ? response.data.payload : response.data;
  }

  marshallData(dataToParse) {
    return this.payloadEnvelope
      ? { data: { payload: dataToParse } }
      : { data: dataToParse };
  }

  async getFromCache() {
    try {
      // IDB is not supported in Firefox private mode: https://bugzilla.mozilla.org/show_bug.cgi?id=781982
      await this.dataManager.initDb();
    } catch {
      return this.getFromNetwork();
    }

    // Trust the IDB cache. Freshness is maintained by the
    // account.cache_invalidated event alone: RoomChannel pushes the cache-key
    // map on every (re)subscribe — boot and reconnect included — and the
    // server broadcasts it on every change. Skipping a per-call /cache_keys
    // preflight eliminates N GET requests per cold settings-page load.
    const localData = await this.dataManager.get({
      modelName: this.cacheModelName,
    });

    if (localData.length > 0) {
      return this.marshallData(localData);
    }

    // Empty IDB (first load or wiped): fetch data without a cache key. The
    // next pushed key map won't match the missing key and will refetch once,
    // stamping the authoritative key — the client never pulls keys itself.
    return this.refetchAndCommit(null);
  }

  async refetchAndCommit(newKey = null) {
    const response = await this.getFromNetwork();

    try {
      await this.dataManager.initDb();

      // Await replace so data is persisted before the cache key is — otherwise
      // a concurrent reader could see a fresh key paired with stale data.
      await this.dataManager.replace({
        modelName: this.cacheModelName,
        data: this.extractDataFromResponse(response),
      });

      await this.dataManager.setCacheKeys({
        [this.cacheModelName]: newKey,
      });
    } catch {
      // Ignore error
    }

    return response;
  }

  async validateCacheKey(cacheKeyFromApi) {
    if (!this.dataManager.db) {
      await this.dataManager.initDb();
    }

    const cacheKey = await this.dataManager.getCacheKey(this.cacheModelName);
    if (cacheKey === undefined) {
      const localData = await this.dataManager.get({
        modelName: this.cacheModelName,
      });
      return localData.length === 0;
    }

    return cacheKeyFromApi === cacheKey;
  }
}

export default CacheEnabledApiClient;
