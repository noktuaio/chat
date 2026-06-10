import CacheEnabledApiClient from './CacheEnabledApiClient';

class LabelsAPI extends CacheEnabledApiClient {
  constructor() {
    super('labels', {
      accountScoped: true,
      cacheModel: 'label',
      payloadEnvelope: true,
    });
  }
}

export default new LabelsAPI();
