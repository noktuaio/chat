import {
  SET_TEAM_UI_FLAG,
  SET_TEAMS,
  SET_TEAM_ITEM,
  EDIT_TEAM,
  DELETE_TEAM,
} from './types';

export const mutations = {
  [SET_TEAM_UI_FLAG]($state, data) {
    $state.uiFlags = {
      ...$state.uiFlags,
      ...data,
    };
  },

  // Replaces (not merges) so rows deleted server-side never survive as
  // phantoms — SET_TEAMS only ever receives the full list.
  [SET_TEAMS]: ($state, data) => {
    const records = {};
    data.forEach(team => {
      records[team.id] = team;
    });
    $state.records = records;
  },

  [SET_TEAM_ITEM]: ($state, data) => {
    $state.records = {
      ...$state.records,
      [data.id]: {
        ...($state.records[data.id] || {}),
        ...data,
      },
    };
  },

  [EDIT_TEAM]: ($state, data) => {
    $state.records = {
      ...$state.records,
      [data.id]: data,
    };
  },

  [DELETE_TEAM]: ($state, teamId) => {
    const { [teamId]: toDelete, ...records } = $state.records;
    $state.records = records;
  },
};
