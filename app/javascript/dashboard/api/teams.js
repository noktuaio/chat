/* global axios */
import CacheEnabledApiClient from './CacheEnabledApiClient';

export class TeamsAPI extends CacheEnabledApiClient {
  constructor() {
    super('teams', { accountScoped: true, cacheModel: 'team' });
  }

  getAgents({ teamId }) {
    return axios.get(`${this.url}/${teamId}/team_members`);
  }

  addAgents({ teamId, agentsList }) {
    return axios.post(`${this.url}/${teamId}/team_members`, {
      user_ids: agentsList,
    });
  }

  updateAgents({ teamId, agentsList }) {
    return axios.patch(`${this.url}/${teamId}/team_members`, {
      user_ids: agentsList,
    });
  }
}

export default new TeamsAPI();
