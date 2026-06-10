/* global axios */

import CacheEnabledApiClient from './CacheEnabledApiClient';

class CannedResponse extends CacheEnabledApiClient {
  constructor() {
    super('canned_responses', {
      accountScoped: true,
      cacheModel: 'canned_response',
    });
  }

  get({ searchKey } = {}) {
    if (searchKey) {
      return axios.get(`${this.url}?search=${searchKey}`);
    }
    return super.get(true);
  }
}

export default new CannedResponse();
