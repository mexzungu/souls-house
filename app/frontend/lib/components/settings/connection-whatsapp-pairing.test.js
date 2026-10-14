import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi } from 'vitest';

const reload = vi.fn();
vi.mock('@inertiajs/svelte', () => ({ router: { reload: (...args) => reload(...args) } }));
vi.mock('qrcode', () => ({ default: { toDataURL: vi.fn(() => Promise.resolve('data:image/png;base64,QR')) } }));

const { default: ConnectionWhatsappPairing } = await import('./connection-whatsapp-pairing.svelte');

const base = '/accounts/house/service_connections/svc_wa';

function reply(status, body) {
  return Promise.resolve({ ok: status < 400, status, json: () => Promise.resolve(body) });
}

function pairingState(extra = {}) {
  return {
    status: 'pairing',
    attempt: 2,
    qr: { code: '2@qr', issued_at: new Date().toISOString(), expires_at: new Date(Date.now() + 60_000).toISOString() },
    phone: {},
    phone_code: null,
    ...extra,
  };
}

// The pairing endpoint answers with `state()`; the phone endpoint with 202
// and `requested`.
function serve(state, requested = { ...pairingState(), phone: { step: 'requested' } }) {
  globalThis.fetch = vi.fn((url) => (url.endsWith('/pairing/phone') ? reply(202, requested) : reply(200, state())));
}

function screenIsPhone(matches) {
  window.matchMedia = vi.fn(() => ({ matches, addEventListener: vi.fn(), removeEventListener: vi.fn() }));
}

function mount(props = {}) {
  return render(ConnectionWhatsappPairing, {
    account: { id: 'house' },
    connection: { id: 'svc_wa', provider: 'whatsapp', status: 'pairing' },
    pollInterval: 60_000,
    ...props,
  });
}

function posts(path) {
  return globalThis.fetch.mock.calls.filter(([url]) => url === `${base}${path}`).map(([, o]) => JSON.parse(o.body));
}

afterEach(() => {
  vi.restoreAllMocks();
  reload.mockReset();
  delete window.matchMedia;
});

describe('WhatsApp pairing card', () => {
  it('leads with the QR on a desktop, and offers the phone number instead', async () => {
    screenIsPhone(false);
    serve(() => pairingState());
    mount();
    expect(await screen.findByAltText('WhatsApp pairing QR code')).toBeInTheDocument();
    expect(screen.queryByLabelText('Phone number')).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'Use a phone number instead' }));
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
    expect(screen.queryByAltText('WhatsApp pairing QR code')).not.toBeInTheDocument();
  });

  it('leads with the phone number on a phone or touch screen, and offers the QR instead', async () => {
    screenIsPhone(true);
    serve(() => pairingState());
    mount();
    expect(await screen.findByLabelText('Phone number')).toBeInTheDocument();
    expect(window.matchMedia).toHaveBeenCalledWith('(max-width: 639px), (pointer: coarse)');
    await fireEvent.click(screen.getByRole('button', { name: 'Scan a QR code instead' }));
    expect(await screen.findByAltText('WhatsApp pairing QR code')).toBeInTheDocument();
  });

  it('sends the number with the attempt, then shows the code as XXXX-XXXX with the WhatsApp steps', async () => {
    let state = pairingState();
    serve(() => state);
    mount({ phoneFirst: true, pollInterval: 50 });
    const input = await screen.findByLabelText('Phone number');
    await fireEvent.input(input, { target: { value: '+44 7700 900123' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Get a code' }));
    await waitFor(() => expect(posts('/pairing/phone')).toEqual([{ phone: '+44 7700 900123', attempt: 2 }]));
    expect(await screen.findByTestId('whatsapp-phone-requesting')).toHaveTextContent('Asking WhatsApp for a code.');

    state = pairingState({
      phone: { step: 'code' },
      phone_code: {
        code: 'ABCD-2345',
        issued_at: new Date().toISOString(),
        expires_at: new Date(Date.now() + 150_000).toISOString(),
      },
    });
    expect(await screen.findByTestId('whatsapp-phone-code')).toHaveTextContent('ABCD-2345');
    const steps = screen.getByTestId('whatsapp-phone-steps');
    expect(steps).toHaveTextContent('Open WhatsApp and go to Settings.');
    expect(steps).toHaveTextContent('Tap Linked devices, then Link a device.');
    expect(steps).toHaveTextContent('Tap “Link with phone number instead”.');
    expect(steps).toHaveTextContent('Enter the code ABCD-2345.');
    expect(screen.getByTestId('whatsapp-phone-countdown')).toHaveTextContent(/expires in 2:(29|30)/);
  });

  it('shows an expired code as expired and leads with restart', async () => {
    serve(() =>
      pairingState({
        phone: { step: 'code' },
        phone_code: { code: 'ABCD-2345', expires_at: new Date(Date.now() - 1_000).toISOString() },
      })
    );
    mount({ phoneFirst: false });
    expect(await screen.findByTestId('whatsapp-phone-countdown')).toHaveTextContent(
      'This code expired. Restart pairing for a new one.'
    );
    expect(screen.queryByRole('button', { name: 'Copy code' })).not.toBeInTheDocument();
  });

  it('explains a failure and asks for the number again', async () => {
    serve(() => pairingState({ phone: { error: 'phone_invalid' } }));
    mount();
    expect(await screen.findByTestId('whatsapp-phone-failure')).toHaveTextContent(/did not accept that number/);
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
  });

  it("shows the server's refusal and keeps the form", async () => {
    globalThis.fetch = vi.fn((url) =>
      url.endsWith('/pairing/phone')
        ? reply(422, {
            error: 'Enter the number of the phone WhatsApp is on: + and the country code, then the number.',
          })
        : reply(200, pairingState())
    );
    mount({ phoneFirst: true });
    await fireEvent.input(await screen.findByLabelText('Phone number'), { target: { value: '07700 900123' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Get a code' }));
    expect(await screen.findByRole('status')).toHaveTextContent(/\+ and the country code/);
    expect(screen.getByLabelText('Phone number')).toBeInTheDocument();
  });

  it('follows a link made by phone number like one made by QR', async () => {
    serve(() => ({ status: 'connected', qr: null, phone: {}, phone_code: null, attempt: 2 }));
    mount({ phoneFirst: true });
    await waitFor(() => expect(reload).toHaveBeenCalled());
  });

  it('takes the new attempt from a restart, so the next number joins it', async () => {
    globalThis.fetch = vi.fn((url) => {
      if (url.endsWith('/pairing/restart'))
        return reply(200, { status: 'pairing', qr: null, attempt: 3, phone: {}, phone_code: null });
      if (url.endsWith('/pairing/phone'))
        return reply(202, { ...pairingState({ attempt: 3 }), phone: { step: 'requested' } });
      return reply(200, pairingState());
    });
    mount({ phoneFirst: true });
    await screen.findByLabelText('Phone number');
    await fireEvent.click(screen.getByRole('button', { name: 'Restart pairing' }));
    await waitFor(() => expect(reload).toHaveBeenCalled());
    await fireEvent.input(screen.getByLabelText('Phone number'), { target: { value: '+44 7700 900123' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Get a code' }));
    await waitFor(() => expect(posts('/pairing/phone')).toEqual([{ phone: '+44 7700 900123', attempt: 3 }]));
  });

  it("refreshes the attempt when a number is refused as an old attempt's", async () => {
    let attempt = 2;
    globalThis.fetch = vi.fn((url) => {
      if (url.endsWith('/pairing/phone')) {
        return reply(409, { error: 'This pairing has moved on. Reload the page and try again.' });
      }
      return reply(200, pairingState({ attempt }));
    });
    mount({ phoneFirst: true });
    await screen.findByLabelText('Phone number');
    attempt = 4;
    await fireEvent.input(screen.getByLabelText('Phone number'), { target: { value: '+44 7700 900123' } });
    await fireEvent.click(screen.getByRole('button', { name: 'Get a code' }));
    expect(await screen.findByRole('status')).toHaveTextContent(/moved on/);
    const polls = () => globalThis.fetch.mock.calls.filter(([url]) => url === `${base}/pairing`).length;
    await waitFor(() => expect(polls()).toBe(2));
  });
});
