import { computed } from 'vue';
import { useMapGetter } from 'dashboard/composables/store';
import { useAccount } from 'dashboard/composables/useAccount';
import { SOCIAL_PLATFORMS, EMAIL_PROVIDERS } from './constants';

// Pull the handle/username out of a detected social URL, formatted per channel.
const extractHandle = ({ type, url }) => {
  try {
    const { pathname } = new URL(url);
    const path = pathname.replace(/^\/+|\/+$/g, '');
    if (type === 'whatsapp') {
      const digits = path.replace(/\D/g, '');
      return digits ? `+${digits}` : '';
    }
    if (type === 'line') return path;
    return path.startsWith('@') ? path : `@${path}`;
  } catch {
    return '';
  }
};

// Derives the channel rows for the inbox-setup step from the account's detected
// brand_info (socials + mailbox provider) and the real connected inboxes,
// keeping InboxSetup.vue focused on layout, connect routing, and completion.
export function useDetectedChannels() {
  const { currentAccount } = useAccount();
  const inboxes = useMapGetter('inboxes/getInboxes');

  const brandSocials = computed(
    () => currentAccount.value?.custom_attributes?.brand_info?.socials || []
  );

  const connectedChannels = computed(() =>
    brandSocials.value
      .filter(social => SOCIAL_PLATFORMS[social.type] && social.url)
      .map(social => ({
        type: social.type,
        handle: extractHandle(social),
        label: SOCIAL_PLATFORMS[social.type].label,
        inbox: { channel_type: SOCIAL_PLATFORMS[social.type].channelType },
      }))
  );

  const detectedEmailChannel = computed(() => {
    const brandInfo = currentAccount.value?.custom_attributes?.brand_info;
    const provider = brandInfo?.email_provider;
    if (!EMAIL_PROVIDERS[provider]) return null;

    return {
      type: 'email',
      handle: brandInfo?.email || '',
      label: EMAIL_PROVIDERS[provider].label,
      inbox: { channel_type: 'Channel::Email', provider },
    };
  });

  // The real inbox backing a channel, if one exists — a connected inbox sharing
  // its channel_type. Gmail and Outlook both use Channel::Email, so for email we
  // also match on provider. Returned (not just a boolean) so the row can show
  // the actual connected account's name rather than the detected handle.
  const connectedInbox = channel =>
    inboxes.value.find(
      inbox =>
        inbox.channel_type === channel.inbox?.channel_type &&
        (channel.inbox?.channel_type !== 'Channel::Email' ||
          inbox.provider === channel.inbox?.provider)
    );

  const displayedChannels = computed(() =>
    [detectedEmailChannel.value, ...connectedChannels.value]
      .filter(Boolean)
      // Email channels (including Gmail/Outlook OAuth) are disabled for this
      // phase; they will be enabled in a future PR.
      .filter(channel => channel.type !== 'email')
  );

  const remainingChannels = computed(() => {
    const connectedTypes = new Set(connectedChannels.value.map(c => c.type));
    return Object.entries(SOCIAL_PLATFORMS)
      .filter(([type]) => !connectedTypes.has(type))
      .slice(0, 3)
      .map(([type, { label, channelType }]) => ({
        type,
        label,
        inbox: { channel_type: channelType },
      }));
  });

  return { displayedChannels, remainingChannels, connectedInbox };
}
