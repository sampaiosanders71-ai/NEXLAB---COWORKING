(function(){
  'use strict';

  if (globalThis.__NEXLAB_RUNTIME_STABILITY_STABLE__) return;

  const VERSION = '26.31.4';
  const REVISION = 'stable-cleanup-r5604';
  const cleanupInFlight = new WeakMap();
  const channelState = new WeakMap();
  let channelSequence = 0;
  let patchedClient = null;

  function dispatch(name, detail){
    try {
      globalThis.dispatchEvent(new CustomEvent(name, { detail: detail || {} }));
    } catch {}
  }

  function cleanupFailure(error, context){
    dispatch('nexlab:realtime-cleanup-error', {
      context,
      message: String(error?.message || error || 'Falha ao encerrar canal Realtime.'),
      stack: String(error?.stack || '')
    });
    return 'error';
  }

  function patchChannel(channel, logicalTopic){
    if (!channel || typeof channel !== 'object') return channel;
    if (channelState.has(channel)) return channel;

    const state = {
      topic: String(logicalTopic || channel.topic || 'realtime'),
      status: 'active',
      unsubscribePromise: null,
      teardownDone: false
    };
    channelState.set(channel, state);

    if (typeof channel.unsubscribe === 'function') {
      const nativeUnsubscribe = channel.unsubscribe.bind(channel);
      channel.unsubscribe = function(timeout){
        if (state.status === 'closed') return Promise.resolve('ok');
        if (state.unsubscribePromise) return state.unsubscribePromise;

        state.status = 'closing';
        state.unsubscribePromise = Promise.resolve()
          .then(() => nativeUnsubscribe(timeout))
          .then((result) => {
            state.status = 'closed';
            return result || 'ok';
          })
          .catch((error) => {
            state.status = 'closed';
            return cleanupFailure(error, `unsubscribe:${state.topic}`);
          });
        return state.unsubscribePromise;
      };
    }

    if (typeof channel.teardown === 'function') {
      const nativeTeardown = channel.teardown.bind(channel);
      channel.teardown = function(){
        if (state.teardownDone) return;
        state.teardownDone = true;
        try { return nativeTeardown(); }
        catch (error) { cleanupFailure(error, `teardown:${state.topic}`); }
      };
    }

    return channel;
  }

  function patchClient(client){
    if (!client || typeof client !== 'object') return client;
    if (client.__nexlabRuntimeStabilityRevision === REVISION) return client;

    const nativeChannel = typeof client.channel === 'function'
      ? client.channel.bind(client)
      : null;
    const nativeRemoveChannel = typeof client.removeChannel === 'function'
      ? client.removeChannel.bind(client)
      : null;

    if (nativeChannel) {
      client.channel = function(topic, options){
        const logicalTopic = String(topic || 'nexlab-realtime');
        const uniqueTopic = `${logicalTopic}-stable-r5604-${++channelSequence}`;
        return patchChannel(nativeChannel(uniqueTopic, options), logicalTopic);
      };
    }

    if (nativeRemoveChannel) {
      client.removeChannel = function(channel){
        if (!channel) return Promise.resolve('ok');
        const existing = cleanupInFlight.get(channel);
        if (existing) return existing;

        const operation = Promise.resolve()
          .then(() => nativeRemoveChannel(channel))
          .catch((error) => cleanupFailure(error, 'remove-channel'))
          .finally(() => cleanupInFlight.delete(channel));
        cleanupInFlight.set(channel, operation);
        return operation;
      };
    }

    if (typeof client.removeAllChannels === 'function') {
      client.removeAllChannels = function(){
        const channels = typeof client.getChannels === 'function'
          ? [...client.getChannels()]
          : [];
        return Promise.all(channels.map((channel) => client.removeChannel(channel)));
      };
    }

    try {
      Object.defineProperty(client, '__nexlabRuntimeStabilityRevision', {
        configurable: false,
        enumerable: false,
        value: REVISION
      });
    } catch {}

    patchedClient = client;
    dispatch('nexlab:runtime-stability-ready', { version: VERSION, revision: REVISION });
    return client;
  }

  let currentClient = globalThis.__NEXLAB_SUPABASE__ || null;
  if (currentClient) currentClient = patchClient(currentClient);

  try {
    const existing = Object.getOwnPropertyDescriptor(globalThis, '__NEXLAB_SUPABASE__');
    if (!existing || existing.configurable) {
      Object.defineProperty(globalThis, '__NEXLAB_SUPABASE__', {
        configurable: true,
        enumerable: true,
        get(){ return currentClient; },
        set(value){ currentClient = patchClient(value); }
      });
    }
  } catch {}

  globalThis.__NEXLAB_RUNTIME_STABILITY_STABLE__ = Object.freeze({
    version: VERSION,
    revision: REVISION,
    patchClient,
    snapshot: () => Object.freeze({
      version: VERSION,
      revision: REVISION,
      clientPatched: Boolean(patchedClient),
      channelsCreated: channelSequence
    })
  });
})();
