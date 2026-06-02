/* global axios */
import ApiClient from '../ApiClient';

class EnterpriseAccountAPI extends ApiClient {
  constructor() {
    super('', { accountScoped: true, enterprise: true });
  }

  checkout() {
    return axios.post(`${this.url}checkout`);
  }

  subscription() {
    return axios.post(`${this.url}subscription`);
  }

  getLimits() {
    return axios.get(`${this.url}limits`);
  }

  toggleDeletion(action) {
    return axios.post(`${this.url}toggle_deletion`, {
      action_type: action,
    });
  }

  createTopupCheckout(credits) {
    return axios.post(`${this.url}topup_checkout`, { credits });
  }

  // Topup packages for the account's billing currency.
  getTopupOptions() {
    return axios.get(`${this.url}topup_options`);
  }

  switchCurrency(currency) {
    return axios.post(`${this.url}switch_currency`, { currency });
  }
}

export default new EnterpriseAccountAPI();
