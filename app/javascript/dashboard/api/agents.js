/* global axios */

import CacheEnabledApiClient from './CacheEnabledApiClient';

class Agents extends CacheEnabledApiClient {
  constructor() {
    super('agents', { accountScoped: true, cacheModel: 'account_user' });
  }

  bulkInvite({ emails }) {
    return axios.post(`${this.url}/bulk_create`, {
      emails,
    });
  }
}

export default new Agents();
