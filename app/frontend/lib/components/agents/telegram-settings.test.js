import { fireEvent, render, screen } from '@testing-library/svelte';
import { get, writable } from 'svelte/store';
import { tick } from 'svelte';
import { router } from '@inertiajs/svelte';
import TelegramSettings from './telegram-settings.svelte';

const link = 'https://example.test/registration/synthetic';
const configuration = { configured: true, username: 'synthetic_bot' };

function settingsProps() {
  return {
    agent: { id: 'resident', name: 'Resident', telegram_configured: true, telegram_bot_username: 'synthetic_bot' },
    form: writable({ agent: { telegram_bot_username: 'synthetic_bot', telegram_bot_token: '' }, processing: false }),
    telegramConfiguration: configuration,
    telegramDeepLink: link,
    telegramSubscriberCount: 1,
  };
}

async function reveal() {
  await fireEvent.click(screen.getByRole('button', { name: 'Reveal registration link' }));
  return router.reload.mock.calls.at(-1)[0];
}

async function finish(request, value = link) {
  request.onSuccess({ props: { telegram_deep_link: value } });
  request.onFinish();
  await tick();
}

test('opening configured settings never reveals a supplied bearer link or requests one automatically', () => {
  render(TelegramSettings, settingsProps());
  expect(screen.queryByText(link)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Reveal registration link' })).toBeEnabled();
  expect(router.reload).not.toHaveBeenCalled();
});

test('only an explicit click requests the deep-link prop and disables duplicate requests while pending', async () => {
  render(TelegramSettings, settingsProps());
  const request = await reveal();
  expect(router.reload).toHaveBeenCalledOnce();
  expect(request).toEqual(
    expect.objectContaining({ only: ['telegram_deep_link'], preserveState: true, preserveScroll: true })
  );
  expect(screen.getByRole('button', { name: 'Revealing...' })).toBeDisabled();
  await finish(request);
  expect(screen.getByText(link)).toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Reveal registration link' })).not.toBeInTheDocument();
});

test('same configuration and count updates preserve a revealed link and typed username/token without reminting', async () => {
  const props = settingsProps();
  const view = render(TelegramSettings, props);
  const username = screen.getByLabelText('Bot username');
  const token = screen.getByLabelText('Bot token');
  await fireEvent.input(username, { target: { value: 'unsaved_bot' } });
  await fireEvent.input(token, { target: { value: 'synthetic-unsaved-token' } });
  await finish(await reveal());
  await view.rerender({
    ...props,
    agent: { ...props.agent, name: 'Renamed resident' },
    telegramConfiguration: { ...configuration },
    telegramSubscriberCount: 7,
    telegramDeepLink: 'https://example.test/registration/unrequested',
  });
  expect(screen.getByText(link)).toBeInTheDocument();
  expect(screen.getByText('7 subscribers connected')).toBeInTheDocument();
  expect(username).toHaveValue('unsaved_bot');
  expect(token).toHaveValue('synthetic-unsaved-token');
  expect(screen.getByLabelText('Bot token')).toBe(token);
  expect(get(props.form).agent.telegram_bot_token).toBe('synthetic-unsaved-token');
  expect(router.reload).toHaveBeenCalledOnce();
});

test.each(['username', 'configured', 'identity'])(
  '%s changes clear the old link without automatically requesting a new one',
  async (change) => {
    const props = settingsProps();
    const view = render(TelegramSettings, props);
    await finish(await reveal());
    const next = {
      ...props,
      agent: { ...props.agent },
      telegramConfiguration: { ...configuration },
    };
    if (change === 'username') {
      next.agent.telegram_bot_username = next.telegramConfiguration.username = 'replacement_bot';
    } else if (change === 'configured') {
      next.agent.telegram_configured = next.telegramConfiguration.configured = false;
    } else {
      next.agent.id = 'another-resident';
    }
    await view.rerender(next);
    expect(screen.queryByText(link)).not.toBeInTheDocument();
    expect(router.reload).toHaveBeenCalledOnce();
    if (change === 'configured') {
      expect(screen.queryByRole('button', { name: 'Reveal registration link' })).not.toBeInTheDocument();
    } else {
      expect(screen.getByRole('button', { name: 'Reveal registration link' })).toBeEnabled();
    }
  }
);

test('a late reveal from the previous configuration cannot publish its link or finish a newer request', async () => {
  const props = settingsProps();
  const view = render(TelegramSettings, props);
  const oldRequest = await reveal();
  await view.rerender({
    ...props,
    agent: { ...props.agent, telegram_bot_username: 'new_bot' },
    telegramConfiguration: { configured: true, username: 'new_bot' },
  });
  const newRequest = await reveal();
  await finish(oldRequest, 'https://example.test/registration/stale');
  expect(screen.queryByText('https://example.test/registration/stale')).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Revealing...' })).toBeDisabled();
  await finish(newRequest, 'https://example.test/registration/current');
  expect(screen.getByText('https://example.test/registration/current')).toBeInTheDocument();
});

test('a late reveal for the previous resident is ignored even when the bot configuration matches', async () => {
  const props = settingsProps();
  const view = render(TelegramSettings, props);
  const request = await reveal();
  await view.rerender({ ...props, agent: { ...props.agent, id: 'next-resident' } });
  await finish(request);
  expect(screen.queryByText(link)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Reveal registration link' })).toBeEnabled();
});
