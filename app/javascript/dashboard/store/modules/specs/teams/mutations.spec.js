import {
  SET_TEAMS,
  SET_TEAM_ITEM,
  EDIT_TEAM,
  DELETE_TEAM,
} from '../../teams/types';
import { mutations } from '../../teams/mutations';
import teams from './fixtures';
describe('#mutations', () => {
  describe('#SET_teams', () => {
    it('set teams records', () => {
      const state = { records: {} };
      mutations[SET_TEAMS](state, [teams[1], teams[2]]);
      expect(state.records).toEqual(teams);
    });

    it('drops records absent from the new list', () => {
      const state = { records: { ...teams } };
      mutations[SET_TEAMS](state, [teams[1]]);
      expect(state.records).toEqual({ 1: teams[1] });
    });
  });

  describe('#ADD_TEAM', () => {
    it('push newly created teams to the store', () => {
      const state = { records: {} };
      mutations[SET_TEAM_ITEM](state, teams[1]);
      expect(state.records).toEqual({ 1: teams[1] });
    });
  });

  describe('#EDIT_TEAM', () => {
    it('update teams record', () => {
      const state = { records: [teams[1]] };
      mutations[EDIT_TEAM](state, {
        id: 1,
        name: 'customer-support',
      });
      expect(state.records[1].name).toEqual('customer-support');
    });
  });

  describe('#DELETE_TEAM', () => {
    it('delete teams record', () => {
      const state = { records: { 1: teams[1] } };
      mutations[DELETE_TEAM](state, 1);
      expect(state.records).toEqual({});
    });
  });
});
