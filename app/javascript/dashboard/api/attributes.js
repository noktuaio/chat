import CacheEnabledApiClient from './CacheEnabledApiClient';

class AttributeAPI extends CacheEnabledApiClient {
  constructor() {
    super('custom_attribute_definitions', {
      accountScoped: true,
      cacheModel: 'custom_attribute_definition',
    });
  }

  getAttributesByModel() {
    return super.get(true);
  }
}

export default new AttributeAPI();
