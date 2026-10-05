// Namibia Eats - single page UI for customers, restaurants, drivers and admins.
// Every call goes through the nginx API gateway: /api/<service>/...
'use strict';

// Served by the nginx gateway (docker compose) the API is same-origin. Opened any other
// way (VS Code Live Server, file://) the UI talks to the gateway on localhost:8080.
// Override with: localStorage.setItem('fd.gateway', 'http://192.168.1.20:8080')
const GATEWAY = (() => {
  try { const saved = localStorage.getItem('fd.gateway'); if (saved) return saved.replace(/\/$/, ''); } catch { /* storage blocked */ }
  return location.protocol.startsWith('http') && location.port === '8080' ? '' : 'http://localhost:8080';
})();
const API = Object.fromEntries(
  ['customer', 'restaurant', 'order', 'payment', 'delivery', 'notification', 'admin']
    .map((s) => [s, `${GATEWAY}/api/${s}-service`]));
const WINDHOEK = [-22.565, 17.083];
const ORDER_STEPS = ['CREATED', 'CONFIRMED', 'PREPARING', 'READY', 'OUT_FOR_DELIVERY', 'DELIVERED'];
const POLL_MS = 2000;

const state = {
  view: 'customer',
  customers: [],
  customer: null,
  restaurants: [],
  restaurant: null,
  menu: [],
  cart: {},
  orderId: null,
  kitchenRestaurantId: null,
  driverId: null,
  maps: {},
};

// ------------------------------------------------------------------ helpers
const $ = (id) => document.getElementById(id);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const nad = (v) => 'N$' + Number(v || 0).toFixed(2);
const chip = (s) => `<span class="chip ${esc(s)}">${esc(String(s).replaceAll('_', ' '))}</span>`;
const ago = (iso) => {
  const s = Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 1000));
  return s < 60 ? `${s}s ago` : s < 3600 ? `${Math.round(s / 60)}m ago` : `${Math.round(s / 3600)}h ago`;
};

async function api(service, path, { method = 'GET', body } = {}) {
  const res = await fetch(API[service] + path, {
    method,
    headers: body ? { 'Content-Type': 'application/json' } : {},
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  if (!res.ok) throw new Error((data && data.message) || `${res.status} ${res.statusText}`);
  return data;
}

function toast(message, kind = '') {
  const el = document.createElement('div');
  el.className = `toast ${kind}`;
  el.textContent = message;
  $('toasts').appendChild(el);
  setTimeout(() => el.remove(), 4500);
}

let online = null;
function setOnline(up, detail = '') {
  if (online === up) return;
  online = up;
  const pill = $('connPill');
  pill.className = 'conn ' + (up ? 'up' : 'down');
  pill.querySelector('b').textContent = up ? 'Live' : 'Offline';
  pill.title = up ? `Connected to ${GATEWAY || location.origin}` : 'API gateway not reachable';
  $('offlineBanner').classList.toggle('hidden', up);
  $('offlineDetail').textContent = detail;
}

async function safe(fn) {
  try { return await fn(); } catch (e) {
    // network failures are shown by the offline banner, not as a toast storm
    if (online !== false && !(e instanceof TypeError) && e.name !== 'TimeoutError') toast(e.message, 'error');
    return undefined;
  }
}

const empty = (icon, text) => `<div class="empty"><span>${icon}</span>${esc(text)}</div>`;

// ------------------------------------------------------------------ maps
function getMap(id) {
  if (!state.maps[id]) {
    const map = L.map(id, { zoomControl: true }).setView(WINDHOEK, 13);
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '&copy; OpenStreetMap contributors',
    }).addTo(map);
    state.maps[id] = { map, layer: L.layerGroup().addTo(map), network: L.layerGroup().addTo(map), fitted: null };
  }
  setTimeout(() => state.maps[id].map.invalidateSize(), 50);
  return state.maps[id];
}

const emojiIcon = (emoji) => L.divIcon({ className: 'driver-icon', html: emoji, iconSize: [24, 24], iconAnchor: [12, 12] });
const ll = (p) => [p.lat, p.lon];

function drawDelivery(mapId, delivery, extra = {}) {
  const m = getMap(mapId);
  m.layer.clearLayers();
  const pickup = delivery?.pickup || extra.pickup;
  const dropoff = delivery?.dropoff || extra.dropoff;
  if (pickup) L.marker(ll(pickup), { icon: emojiIcon('🍽️') }).bindTooltip(delivery?.restaurantName || 'Restaurant').addTo(m.layer);
  if (dropoff) L.marker(ll(dropoff), { icon: emojiIcon('🏠') }).bindTooltip('Customer').addTo(m.layer);
  if (delivery?.route?.length) {
    L.polyline(delivery.route.map(ll), { color: delivery.leg === 'TO_CUSTOMER' ? '#2e7d4f' : '#c4572a', weight: 5, opacity: .75 }).addTo(m.layer);
  }
  if (delivery?.currentLocation) {
    L.marker(ll(delivery.currentLocation), { icon: emojiIcon('🛵'), zIndexOffset: 1000 })
      .bindTooltip(`${delivery.driverName || 'Driver'}${delivery.etaSeconds ? ' · ETA ' + delivery.etaSeconds + 's' : ''}`, { permanent: true, direction: 'top', offset: [0, -10] })
      .addTo(m.layer);
  }
  const key = (delivery?.deliveryId || '') + (delivery?.leg || '');
  const points = [pickup, dropoff, delivery?.currentLocation].filter(Boolean).map(ll);
  if (points.length && m.fitted !== key) {
    m.map.fitBounds(L.latLngBounds(points).pad(0.3));
    m.fitted = key;
  }
}

// ------------------------------------------------------------------ navigation
document.querySelectorAll('#tabs button').forEach((btn) => btn.addEventListener('click', () => {
  document.querySelectorAll('#tabs button').forEach((b) => b.classList.toggle('active', b === btn));
  document.querySelectorAll('.view').forEach((v) => v.classList.toggle('active', v.id === 'view-' + btn.dataset.view));
  state.view = btn.dataset.view;
  refresh();
  Object.values(state.maps).forEach((m) => setTimeout(() => m.map.invalidateSize(), 60));
}));

// ================================================================== CUSTOMER
async function loadCustomers(selectId) {
  state.customers = await api('customer', '/customers');
  const sel = $('customerSelect');
  sel.innerHTML = state.customers.map((c) => `<option value="${esc(c.customerId)}">${esc(c.name)} (${esc(c.email)})</option>`).join('');
  if (selectId) sel.value = selectId;
  selectCustomer(sel.value);
}

function selectCustomer(id) {
  state.customer = state.customers.find((c) => c.customerId === id) || null;
  state.orderId = null;
  $('tracking').classList.add('hidden');
  const c = state.customer;
  $('customerInfo').innerHTML = c
    ? `${esc(c.phone)} · ${c.totalOrders} delivered orders · spent ${nad(c.totalSpent)}<br>Alerts: ${['email', 'sms', 'push'].filter((k) => c.notificationPrefs[k]).join(', ')}`
    : '';
  $('addressSelect').innerHTML = (c?.addresses || []).map((a) =>
    `<option value="${esc(a.addressId)}" ${a.isDefault ? 'selected' : ''}>${esc(a.label)} - ${esc(a.street)}</option>`).join('');
  renderCart();
  refreshCustomer();
}

$('customerSelect').addEventListener('change', (e) => selectCustomer(e.target.value));
$('addressSelect').addEventListener('change', renderCart);

async function loadRestaurants() {
  state.restaurants = await api('restaurant', '/restaurants');
  $('restaurantList').innerHTML = state.restaurants.map((r) => `
    <div class="item ${state.restaurant?.restaurantId === r.restaurantId ? 'selected' : ''} ${r.isOpenNow && r.acceptingOrders ? '' : 'disabled'}"
         data-id="${esc(r.restaurantId)}">
      <div><div class="title">${esc(r.name)}</div><div class="sub">${esc(r.cuisine)} · ★ ${r.rating} · ${esc(r.address)}</div></div>
      ${r.isOpenNow && r.acceptingOrders ? '<span class="chip open">OPEN</span>' : '<span class="chip closed">CLOSED</span>'}
    </div>`).join('') || empty('🏪', 'No restaurants yet');
  $('restaurantList').querySelectorAll('.item').forEach((el) => el.addEventListener('click', () => openRestaurant(el.dataset.id)));
  fillRestaurantSelect();
}

async function openRestaurant(id) {
  state.restaurant = state.restaurants.find((r) => r.restaurantId === id);
  state.cart = {};
  state.menu = await api('restaurant', `/restaurants/${id}/menu`);
  $('menuTitle').innerHTML = `<span class="ico">📋</span> ${esc(state.restaurant.name)}`;
  loadRestaurants();
  renderMenu();
  renderCart();
}

function renderMenu() {
  const open = state.restaurant?.isOpenNow && state.restaurant?.acceptingOrders;
  $('menuList').innerHTML = state.menu.map((m) => {
    const soldOut = !m.available || m.stock <= 0;
    return `<div class="item ${soldOut ? 'disabled' : ''}">
      <div><div class="title">${esc(m.name)}</div><div class="sub">${esc(m.description)} · ${m.stock} left</div></div>
      <div class="qty">
        <b>${nad(m.price)}</b>
        <button data-id="${esc(m.itemId)}" ${soldOut || !open ? 'disabled' : ''}>+</button>
      </div>
    </div>`;
  }).join('') || empty('🍽️', 'No dishes on this menu yet');
  $('menuList').querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
    state.cart[b.dataset.id] = (state.cart[b.dataset.id] || 0) + 1;
    renderCart();
  }));
}

let quoteTimer = null;
function renderCart() {
  const lines = Object.entries(state.cart).filter(([, q]) => q > 0);
  $('cart').classList.toggle('hidden', lines.length === 0);
  let subtotal = 0;
  $('cartLines').innerHTML = lines.map(([id, q]) => {
    const item = state.menu.find((m) => m.itemId === id);
    subtotal += item.price * q;
    return `<div class="cart-line"><span class="qty"><button data-id="${esc(id)}" data-d="-1">−</button>${q} × ${esc(item.name)}</span><span>${nad(item.price * q)}</span></div>`;
  }).join('');
  $('cartLines').querySelectorAll('button').forEach((b) => b.addEventListener('click', () => {
    state.cart[b.dataset.id] += Number(b.dataset.d);
    renderCart();
  }));
  clearTimeout(quoteTimer);
  if (lines.length) quoteTimer = setTimeout(() => updateQuote(subtotal), 150);
}

async function updateQuote(subtotal) {
  const address = state.customer?.addresses.find((a) => a.addressId === $('addressSelect').value);
  if (!address || !state.restaurant) return;
  const q = await safe(() => api('order', `/pricing/quote?restaurantId=${state.restaurant.restaurantId}&lat=${address.location.lat}&lon=${address.location.lon}`));
  if (!q) return;
  $('quote').innerHTML = `
    Subtotal <b>${nad(subtotal)}</b><br>
    Delivery (${q.estimatedDistanceKm} km) <b>${nad(q.deliveryFee)}</b>
    ${q.surgeMultiplier > 1 ? `<br><span class="chip PREPARING">SURGE ×${q.surgeMultiplier.toFixed(2)}</span> <span class="small muted">${esc(q.surgeReasons.join('; '))}</span>` : ''}
    <div class="total">Total ${nad(subtotal + q.deliveryFee)}</div>`;
}

$('paymentMethod').addEventListener('change', (e) => { $('cardLast4').disabled = e.target.value !== 'CARD'; });

$('btnPlaceOrder').addEventListener('click', () => safe(async () => {
  const items = Object.entries(state.cart).filter(([, q]) => q > 0).map(([itemId, quantity]) => ({ itemId, quantity }));
  const method = $('paymentMethod').value;
  const order = await api('order', '/orders', {
    method: 'POST',
    body: {
      customerId: state.customer.customerId,
      restaurantId: state.restaurant.restaurantId,
      items,
      addressId: $('addressSelect').value,
      paymentMethod: method,
      cardLast4: method === 'CARD' ? $('cardLast4').value : null,
    },
  });
  toast(`Order ${order.orderId} placed - ${nad(order.total)}`, 'ok');
  state.cart = {};
  renderCart();
  state.orderId = order.orderId;
  refreshCustomer();
}));

$('btnCancelOrder').addEventListener('click', () => safe(async () => {
  await api('order', `/orders/${state.orderId}/cancel`, { method: 'PUT', body: { reason: 'Changed my mind' } });
  toast('Order cancelled - refund will follow if you already paid', 'ok');
  refreshCustomer();
}));

async function refreshCustomer() {
  if (!state.customer) return;
  const orders = await api('order', `/orders?customerId=${state.customer.customerId}&limit=15`);
  $('orderList').innerHTML = orders.map((o) => `
    <div class="item ${o.orderId === state.orderId ? 'selected' : ''}" data-id="${esc(o.orderId)}">
      <div><div class="title">${esc(o.orderId)} · ${esc(o.restaurantName)}</div><div class="sub">${nad(o.total)} · ${ago(o.createdAt)}</div></div>
      ${chip(o.status)}
    </div>`).join('') || empty('🧾', 'No orders yet - your first one is a click away');
  $('orderList').querySelectorAll('.item').forEach((el) => el.addEventListener('click', () => { state.orderId = el.dataset.id; refreshCustomer(); }));
  const order = orders.find((o) => o.orderId === state.orderId);
  if (order) await renderTracking(order);
}

async function renderTracking(order) {
  $('tracking').classList.remove('hidden');
  $('trackTitle').textContent = `Tracking ${order.orderId}`;
  $('btnCancelOrder').disabled = !['CREATED', 'CONFIRMED'].includes(order.status);
  const idx = ORDER_STEPS.indexOf(order.status);
  const stepper = $('stepper');
  stepper.classList.toggle('cancelled', order.status === 'CANCELLED');
  stepper.innerHTML = ORDER_STEPS.map((s, i) =>
    `<li class="${i < idx || order.status === 'DELIVERED' ? 'done' : i === idx ? 'current' : ''}">${s.replaceAll('_', ' ')}</li>`).join('');
  const delivery = await api('delivery', `/deliveries/order/${order.orderId}`).catch(() => null);
  let info = `${chip(order.status)} ${order.items.map((i) => `${i.quantity}× ${esc(i.name)}`).join(', ')} · ${nad(order.total)}`;
  if (order.surgeMultiplier > 1) info += ` · surge ×${order.surgeMultiplier}`;
  if (order.cancelReason) info += `<br><b>Reason:</b> ${esc(order.cancelReason)}`;
  if (delivery?.driverName) info += `<br>Driver <b>${esc(delivery.driverName)}</b> ${chip(delivery.status)}${delivery.etaSeconds ? ` · arriving in ~${delivery.etaSeconds}s` : ''}`;
  else if (delivery?.status === 'PENDING_ASSIGNMENT') info += '<br>Looking for a driver…';
  $('trackInfo').innerHTML = info;
  drawDelivery('trackMap', delivery, { pickup: order.restaurantLocation, dropoff: order.deliveryAddress.location });
  const notes = await api('notification', `/notifications?recipientType=CUSTOMER&recipientId=${order.customerId}&orderId=${order.orderId}&limit=20`).catch(() => []);
  $('customerNotifications').innerHTML = renderNotes(notes);
}

function renderNotes(notes) {
  return notes.map((n) => `<div class="note ${esc(n.channel)}"><b>${esc(n.title)}</b>${esc(n.body)}
    <div class="meta">${esc(n.channel)} → ${esc(n.destination)} · ${ago(n.createdAt)}</div></div>`).join('')
    || '<p class="muted small">Nothing yet.</p>';
}

$('btnRegister').addEventListener('click', () => $('registerDialog').showModal());
$('registerDialog').addEventListener('close', () => {
  if ($('registerDialog').returnValue !== 'ok') return;
  const f = new FormData($('registerForm'));
  safe(async () => {
    const c = await api('customer', '/customers', {
      method: 'POST',
      body: {
        name: f.get('name'), email: f.get('email'), phone: f.get('phone'), password: f.get('password'),
        address: { label: 'Home', street: f.get('street'), city: 'Windhoek', location: { lat: -22.5705, lon: 17.0860 }, isDefault: true },
      },
    });
    toast(`Welcome ${c.name}! A welcome email is on its way.`, 'ok');
    await loadCustomers(c.customerId);
  });
});

// ================================================================ RESTAURANT
function fillRestaurantSelect() {
  const sel = $('restaurantSelect');
  const current = sel.value || state.kitchenRestaurantId;
  sel.innerHTML = state.restaurants.map((r) => `<option value="${esc(r.restaurantId)}">${esc(r.name)}</option>`).join('');
  if (current) sel.value = current;
  state.kitchenRestaurantId = sel.value;
}
$('restaurantSelect').addEventListener('change', (e) => { state.kitchenRestaurantId = e.target.value; refreshRestaurant(); });

$('acceptingToggle').addEventListener('change', (e) => safe(async () => {
  await api('restaurant', `/restaurants/${state.kitchenRestaurantId}/accepting`, { method: 'PUT', body: { acceptingOrders: e.target.checked } });
  toast(e.target.checked ? 'Now accepting orders' : 'Paused new orders', 'ok');
  loadRestaurants();
}));

async function refreshRestaurant() {
  const id = state.kitchenRestaurantId;
  if (!id) return;
  const [r, tickets, menu, notes] = await Promise.all([
    api('restaurant', `/restaurants/${id}`),
    api('restaurant', `/restaurants/${id}/kitchen?status=QUEUED,PREPARING,READY`),
    api('restaurant', `/restaurants/${id}/menu`),
    api('notification', `/notifications?recipientType=RESTAURANT&recipientId=${id}&limit=20`).catch(() => []),
  ]);
  $('acceptingToggle').checked = r.acceptingOrders;
  $('restaurantOpen').className = `chip ${r.isOpenNow ? 'open' : 'closed'}`;
  $('restaurantOpen').textContent = r.isOpenNow ? 'KITCHEN OPEN' : 'KITCHEN CLOSED';
  $('restaurantHours').textContent = r.openingHours.map((h) => `${h.day} ${h.open}-${h.close}`).join(' · ');
  for (const lane of ['QUEUED', 'PREPARING', 'READY']) {
    $('lane-' + lane).innerHTML = tickets.filter((t) => t.status === lane).map((t) => `
      <div class="ticket">
        <div class="head"><span>${esc(t.orderId)}</span><span class="muted small">${ago(t.receivedAt)}</span></div>
        <div class="small muted">${esc(t.customerName)}</div>
        <ul>${t.items.map((i) => `<li>${i.quantity}× ${esc(i.name)}</li>`).join('')}</ul>
        ${lane === 'QUEUED' ? `<button class="primary small" data-act="start" data-id="${esc(t.orderId)}">Start cooking</button>` : ''}
        ${lane === 'PREPARING' ? `<button class="primary small" data-act="ready" data-id="${esc(t.orderId)}">Mark ready</button>` : ''}
        ${lane === 'READY' ? '<span class="small muted">Waiting for driver…</span>' : ''}
      </div>`).join('') || '<p class="muted small">Empty</p>';
  }
  document.querySelectorAll('.lane button').forEach((b) => b.addEventListener('click', () => safe(async () => {
    await api('restaurant', `/restaurants/${id}/kitchen/${b.dataset.id}/${b.dataset.act}`, { method: 'POST' });
    refreshRestaurant();
  })));
  const table = $('inventoryTable');
  if (!table.contains(document.activeElement)) {
    table.innerHTML = `<tr><th>Dish</th><th class="num">Price</th><th class="num">Stock</th><th></th></tr>` + menu.map((m) => `
      <tr><td>${esc(m.name)}<div class="small muted">${esc(m.category)}</div></td>
        <td class="num">${nad(m.price)}</td>
        <td class="num">${m.stock <= 5 ? `<span class="chip FAILED">${m.stock}</span>` : m.stock}</td>
        <td class="num"><input type="number" min="0" value="${m.stock}" data-id="${esc(m.itemId)}"><button class="small" data-save="${esc(m.itemId)}">Set</button></td></tr>`).join('');
    table.querySelectorAll('button[data-save]').forEach((b) => b.addEventListener('click', () => safe(async () => {
      const input = table.querySelector(`input[data-id="${b.dataset.save}"]`);
      await api('restaurant', `/restaurants/${id}/menu/${b.dataset.save}/stock`, { method: 'PATCH', body: { stock: Number(input.value) } });
      toast('Inventory updated', 'ok');
      input.blur();
      refreshRestaurant();
    })));
  }
  $('restaurantNotifications').innerHTML = renderNotes(notes);
}

// ==================================================================== DRIVER
async function loadDrivers() {
  const drivers = await api('delivery', '/drivers');
  const sel = $('driverSelect');
  const current = sel.value;
  sel.innerHTML = drivers.map((d) => `<option value="${esc(d.driverId)}">${esc(d.name)} (${esc(d.vehicle)})</option>`).join('');
  if (current) sel.value = current;
  state.driverId = sel.value;
}
$('driverSelect').addEventListener('change', (e) => { state.driverId = e.target.value; getMap('driverMap').fitted = null; refreshDriver(); });

const setDriverStatus = (status) => safe(async () => {
  await api('delivery', `/drivers/${state.driverId}/status`, { method: 'PUT', body: { status } });
  toast(`Driver is now ${status}`, 'ok');
  refreshDriver();
});
$('btnDriverOnline').addEventListener('click', () => setDriverStatus('AVAILABLE'));
$('btnDriverOffline').addEventListener('click', () => setDriverStatus('OFFLINE'));

let activeDelivery = null;
$('btnPickup').addEventListener('click', () => safe(async () => {
  await api('delivery', `/deliveries/${activeDelivery.deliveryId}/pickup`, { method: 'PUT' });
  toast('Pickup confirmed', 'ok');
  refreshDriver();
}));
$('btnComplete').addEventListener('click', () => safe(async () => {
  await api('delivery', `/deliveries/${activeDelivery.deliveryId}/complete`, { method: 'PUT' });
  toast('Delivery completed', 'ok');
  refreshDriver();
}));

async function refreshDriver() {
  const id = state.driverId;
  if (!id) return;
  const [driver, deliveries, notes] = await Promise.all([
    api('delivery', `/drivers/${id}`),
    api('delivery', `/drivers/${id}/deliveries`),
    api('notification', `/notifications?recipientType=DRIVER&recipientId=${id}&limit=20`).catch(() => []),
  ]);
  $('driverStatus').className = `chip ${driver.status}`;
  $('driverStatus').textContent = driver.status;
  $('driverStats').textContent = `${driver.completedDeliveries} deliveries · ${driver.totalDistanceKm.toFixed(1)} km · earned ${nad(driver.earnings)} · ★ ${driver.rating}`;
  activeDelivery = deliveries.find((d) => ['ASSIGNED', 'AT_RESTAURANT', 'PICKED_UP'].includes(d.status)) || null;
  const d = activeDelivery;
  $('driverJob').innerHTML = d ? `
      <div class="item"><div><div class="title">${esc(d.orderId)} · ${esc(d.restaurantName)}</div>
      <div class="sub">to ${esc(d.customerName)}, ${esc(d.dropoffAddress)}</div>
      <div class="sub">${d.leg === 'TO_RESTAURANT' ? 'Heading to restaurant' : d.leg === 'TO_CUSTOMER' ? 'Heading to customer' : ''}
        · ${d.routeDistanceKm} km route${d.etaSeconds ? ` · ETA ${d.etaSeconds}s` : ''} · food ${d.foodReady ? 'ready ✅' : 'cooking 🍳'}</div></div>
      ${chip(d.status)}</div>` : empty('🛵', 'No active delivery. Go online to receive jobs.');
  $('btnPickup').disabled = !(d && d.foodReady && ['ASSIGNED', 'AT_RESTAURANT'].includes(d.status));
  $('btnComplete').disabled = !(d && d.status === 'PICKED_UP');
  if (d) drawDelivery('driverMap', d);
  else {
    const m = getMap('driverMap');
    m.layer.clearLayers();
    L.marker(ll(driver.location), { icon: emojiIcon('🛵') }).bindTooltip(driver.name).addTo(m.layer);
  }
  $('driverNotifications').innerHTML = renderNotes(notes);
  $('driverHistory').innerHTML = deliveries.filter((x) => x !== d).slice(0, 10).map((x) => `
    <div class="item"><div><div class="title">${esc(x.orderId)}</div><div class="sub">${esc(x.restaurantName)} → ${esc(x.customerName)} · ${x.travelledKm} km</div></div>${chip(x.status)}</div>`).join('')
    || '<p class="muted small">No deliveries yet.</p>';
}

// ===================================================================== ADMIN
let networkDrawn = false;
async function refreshAdmin() {
  const [o, restaurants, deliveries, hourly, events, fleet, health, dead, drivers] = await Promise.all([
    api('admin', '/reports/overview'),
    api('admin', '/reports/restaurants'),
    api('admin', '/reports/deliveries'),
    api('admin', '/reports/hourly'),
    api('admin', '/reports/events'),
    api('admin', '/reports/fleet'),
    api('admin', '/reports/system'),
    api('admin', '/reports/dead-letters'),
    api('delivery', '/drivers'),
  ]);
  const kpi = (label, value, sub = '') => `<div class="kpi"><div class="label">${label}</div><div class="value">${value}${sub ? ` <small>${sub}</small>` : ''}</div></div>`;
  $('kpis').innerHTML = [
    kpi('Orders', o.totalOrders, `${o.activeOrders} active`),
    kpi('Delivered', o.delivered),
    kpi('Cancelled', o.cancelled, `${Math.round(o.cancellationRate * 100)}%`),
    kpi('GMV', nad(o.grossMerchandiseValue)),
    kpi('Avg order', nad(o.avgOrderValue)),
    kpi('Order → door', o.avgFulfilmentMinutes, 'min'),
    kpi('Kitchen prep', o.avgPrepMinutes, 'min'),
    kpi('On time', Math.round(o.onTimeRate * 100) + '%', `≤ ${o.onTimeTargetMinutes} min`),
    kpi('Avg surge', '×' + o.avgSurgeMultiplier.toFixed(2), `${o.surgedOrders} surged`),
    kpi('Payment failures', o.paymentFailures, `${o.refunds} refunds`),
  ].join('');

  $('restaurantStats').innerHTML = `<tr><th>Restaurant</th><th class="num">Orders</th><th class="num">Delivered</th><th class="num">Revenue</th><th class="num">Avg prep</th><th class="num">Cancel</th></tr>` +
    restaurants.map((r) => `<tr><td>${esc(r.restaurantName)}</td><td class="num">${r.orders}</td><td class="num">${r.delivered}</td>
      <td class="num">${nad(r.revenue)}</td><td class="num">${r.avgPrepMinutes} min</td><td class="num">${Math.round(r.cancellationRate * 100)}%</td></tr>`).join('');

  $('driverStatsTable').innerHTML = `<tr><th>Driver</th><th class="num">Deliveries</th><th class="num">Active</th><th class="num">Distance</th><th class="num">Avg transit</th><th class="num">Fees</th></tr>` +
    deliveries.drivers.map((d) => `<tr><td>${esc(d.driverName)}</td><td class="num">${d.deliveries}</td><td class="num">${d.inProgress}</td>
      <td class="num">${d.totalDistanceKm} km</td><td class="num">${d.avgTransitMinutes} min</td><td class="num">${nad(d.deliveryFeesEarned)}</td></tr>`).join('');

  const max = Math.max(1, ...hourly.map((h) => h.orders));
  $('hourly').innerHTML = hourly.map((h) => `<div class="bar" style="height:${(h.orders / max) * 100}%" title="${h.hour}:00 - ${h.orders} orders, ${nad(h.revenue)}"><span>${h.hour % 3 === 0 ? h.hour : ''}</span></div>`).join('');

  $('eventsTable').innerHTML = `<tr><th>Topic</th><th class="num">Events</th><th>Last</th></tr>` +
    events.map((e) => `<tr><td><code>${esc(e.topic)}</code></td><td class="num">${e.count}</td><td class="small muted">${esc(e.lastEventType)} · ${ago(e.lastEventAt)}</td></tr>`).join('');

  $('health').innerHTML = health.map((h) => `<div class="svc"><span>${esc(h.service)}</span><span>${chip(h.status)} <span class="muted small">${h.latencyMs}ms</span></span></div>`).join('');

  $('deadLetters').innerHTML = dead.map((d) => `<div class="note"><b>${esc(d.failedTopic)} @ ${esc(d.consumer)}</b>${esc(d.reason)}<div class="meta">${ago(d.failedAt)}</div></div>`).join('')
    || '<p class="muted small">No poison messages 🎉</p>';

  const m = getMap('fleetMap');
  if (!networkDrawn) {
    networkDrawn = true;
    const segments = await api('delivery', '/routes/network').catch(() => []);
    segments.forEach((s) => L.polyline([ll(s.from), ll(s.to)], {
      color: s.congested ? '#c0392b' : s.arterial ? '#2b6cb0' : '#9aa0a6', weight: s.arterial ? 3 : 1.5, opacity: .55,
    }).addTo(m.network));
  }
  m.layer.clearLayers();
  const positions = Object.fromEntries(fleet.map((p) => [p.driverId, p]));
  drivers.forEach((d) => {
    const live = positions[d.driverId];
    const p = d.status === 'BUSY' && live ? live : d.location;
    L.marker([p.lat, p.lon], { icon: emojiIcon(d.status === 'BUSY' ? '🛵' : d.status === 'AVAILABLE' ? '🟢' : '⚪') })
      .bindTooltip(`${d.name} · ${d.status}${live && d.status === 'BUSY' ? ` · ${live.leg} ${live.progressPct}%` : ''}`).addTo(m.layer);
  });
  state.restaurants.forEach((r) => L.marker(ll(r.location), { icon: emojiIcon('🍽️') }).bindTooltip(r.name).addTo(m.layer));
}

$('networkToggle').addEventListener('change', (e) => {
  const m = getMap('fleetMap');
  if (e.target.checked) m.network.addTo(m.map); else m.network.remove();
});

// ===================================================================== LOOP
async function refreshSurge() {
  const s = await api('order', '/pricing/surge').catch(() => null);
  if (!s) return;
  const badge = $('surgeBadge');
  badge.textContent = `Surge ×${s.multiplier.toFixed(2)} · ${s.level}`;
  badge.className = 'surge ' + s.level.toLowerCase();
  badge.title = s.reasons.join('\n') || 'Normal pricing';
}

let refreshing = false;
let loaded = false;

async function ping() {
  try {
    const res = await fetch(API.order + '/health', { cache: 'no-store', signal: AbortSignal.timeout(5000) });
    setOnline(res.ok, res.ok ? '' : `(gateway answered ${res.status} - the services may still be starting)`);
  } catch {
    setOnline(false, `(tried ${GATEWAY || location.origin})`);
  }
  return online;
}

async function loadAll() {
  await safe(async () => {
    await loadRestaurants();
    await loadCustomers();
    await loadDrivers();
    loaded = true;
  });
}

async function refresh() {
  if (refreshing) return;
  refreshing = true;
  try {
    if (!(await ping())) return;
    if (!loaded) await loadAll();
    if (state.view === 'customer') await refreshCustomer();
    if (state.view === 'restaurant') await refreshRestaurant();
    if (state.view === 'driver') { if (!state.driverId) await loadDrivers(); await refreshDriver(); }
    if (state.view === 'admin') await refreshAdmin();
    await refreshSurge();
  } catch (e) {
    console.warn(e);
  } finally {
    refreshing = false;
  }
}

(function start() {
  refresh();
  setInterval(refresh, POLL_MS);
  setInterval(() => { if (state.view === 'customer') loadRestaurants().catch(() => {}); }, 15000);
})();
