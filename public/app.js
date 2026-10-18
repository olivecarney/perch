import { logos, logoNames, localLogo, fallbackLogo, resolveLogo } from '/logos.mjs';

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const icon = name => `<svg aria-hidden="true"><use href="#i-${name}"/></svg>`;
const escape = value => String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
const editor = $('#editor');
const form = $('#app-form');
let apps = [], editing = false, busy = false, uploading = false;
let selectedLogo = 'auto', previewVersion = 0, drag = null, toastTimer;

function notify(message) {
  $('#toast').textContent = message;
  $('#toast').hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => $('#toast').hidden = true, 2400);
}
function setBusy(value) {
  busy = value;
  for (const button of $$('button')) button.disabled = value || button.dataset.boundary === 'true';
}
async function request(change) {
  const response = await fetch('/api/apps', change ? {
    method: 'POST', headers: {'Content-Type':'application/json'},
    body: JSON.stringify(change), cache: 'no-store',
  } : {cache:'no-store'});
  if (!response.ok) {
    if (response.status === 400) throw new Error((await response.text()).replace(/<[^>]*>/g,'').slice(0,180));
    if (response.status === 404) throw new Error('The app list changed. Reload to refresh.');
    throw new Error('Could not save. Check the server and data folder.');
  }
  return response.json();
}

const visibleLogos = new IntersectionObserver(entries => {
  for (const entry of entries) {
    if (!entry.isIntersecting) continue;
    const image = entry.target;
    visibleLogos.unobserve(image);
    const app = apps.find(app => app.id === Number(image.dataset.app));
    if (app) resolveLogo(app).then(source => { if (image.isConnected) image.src = source; });
  }
}, {rootMargin:'100px'});

function render() {
  visibleLogos.disconnect();
  $('#apps').classList.toggle('editing', editing);
  $('#arrange').setAttribute('aria-pressed', String(editing));
  $('#arrange').setAttribute('aria-label', editing ? 'Done editing' : 'Edit apps');
  $('#arrange').title = editing ? 'Done editing' : 'Edit apps';
  $('#arrange').innerHTML = icon(editing ? 'check' : 'edit');
  $('#arrange').hidden = apps.length === 0;
  $('#apps').innerHTML = apps.map((app, index) => `
    <article class="app-card" data-id="${app.id}">
      <div class="card-controls">
        <button class="icon-button drag-handle" aria-label="Drag ${escape(app.name)} to reorder" title="Drag to reorder">${icon('grip')}</button>
        <button class="icon-button" data-edit="${app.id}" aria-label="Edit ${escape(app.name)}" title="Edit app">${icon('more')}</button>
      </div>
      <a class="app-link" href="${escape(app.address)}" target="_blank" rel="noopener noreferrer" aria-label="Open ${escape(app.name)} in a new tab" title="${escape(app.address)}">
        <img class="app-logo" data-app="${app.id}" src="${fallbackLogo(app)}" alt="" width="45" height="45" loading="lazy" referrerpolicy="no-referrer">
        <span class="app-name">${escape(app.name)}</span><svg class="launch-arrow" aria-hidden="true"><use href="#i-arrow"/></svg>
      </a>
      ${editing ? `<div class="move-controls">
        <button class="icon-button" data-move="-1" data-app="${app.id}" data-boundary="${index === 0}" ${index === 0 ? 'disabled' : ''} aria-label="Move ${escape(app.name)} earlier" title="Move earlier">${icon('left')}</button>
        <button class="icon-button" data-move="1" data-app="${app.id}" data-boundary="${index === apps.length - 1}" ${index === apps.length - 1 ? 'disabled' : ''} aria-label="Move ${escape(app.name)} later" title="Move later">${icon('right')}</button>
      </div>` : ''}
    </article>`).join('') + (apps.length ? '' : `<button class="add-tile" data-add aria-label="Add app" title="Add app">${icon('plus')}</button>`);
  for (const image of $$('.app-logo')) visibleLogos.observe(image);
}

function normalizedAddress(value) {
  try {
    const url = new URL(value.includes('://') ? value : `http://${value}`);
    return ['http:','https:'].includes(url.protocol) && !url.username && !url.password ? url.href : null;
  } catch { return null; }
}
async function previewLogo() {
  const version = ++previewVersion;
  const address = normalizedAddress(form.elements.address.value.trim());
  const app = {name:form.elements.name.value, address:address || 'http://localhost/', logo:selectedLogo};
  $('#logo-preview').src = fallbackLogo(app);
  if (selectedLogo === 'auto' && !address) return;
  const source = await resolveLogo(app);
  if (version === previewVersion && editor.open) $('#logo-preview').src = source;
}
function chooseLogo(logo) {
  selectedLogo = logo;
  const index = logos.indexOf(logo);
  $('#logo-label').textContent = logo === 'auto' ? 'Automatic' : index >= 0 ? logoNames[index] : logo.startsWith('data:') ? 'Uploaded' : 'Custom';
  $('#auto-logo').classList.toggle('selected', logo === 'auto');
  $('#auto-logo').setAttribute('aria-pressed', String(logo === 'auto'));
  for (const button of $$('.logo-choice')) {
    button.classList.toggle('selected', button.dataset.logo === logo);
    button.setAttribute('aria-pressed', String(button.dataset.logo === logo));
  }
  previewLogo();
}
function openEditor(id) {
  if (busy || drag) return;
  const app = apps.find(app => app.id === id);
  form.reset();
  form.elements.id.value = app?.id || 0;
  form.elements.name.value = app?.name || '';
  form.elements.address.value = app?.address || '';
  $('#logo-file').value = '';
  $('#logo-url').value = app && !logos.includes(app.logo) && app.logo !== 'auto' && !app.logo.startsWith('data:') ? app.logo : '';
  $('#logo-details').open = false;
  $('#form-error').hidden = true;
  $('#dialog-title').textContent = app ? 'Edit app' : 'Add app';
  $('#save-app').textContent = app ? 'Save' : 'Add app';
  $('#delete-app').hidden = !app;
  $('#logo-options').innerHTML = logos.map((logo,index) => `<button type="button" class="logo-choice" data-logo="${logo}" aria-label="${logoNames[index]} logo"><img src="${localLogo(logo)}" alt="" width="24" height="24"></button>`).join('');
  editor.showModal();
  chooseLogo(app?.logo || 'auto');
  form.elements.name.focus();
}
function showError(message) {
  $('#form-error').textContent = message;
  $('#form-error').hidden = false;
}
async function save(event) {
  event.preventDefault();
  if (busy || uploading) return;
  const id = Number(form.elements.id.value);
  // Preserve hidden legacy fields when editing an existing collection.
  const app = {...apps.find(app => app.id === id), id, name:form.elements.name.value,
    address:form.elements.address.value, logo:$('#logo-url').value.trim() || selectedLogo};
  setBusy(true);
  $('#form-error').hidden = true;
  try {
    apps = await request({action:'save',app});
    editor.close(); render();
  } catch (error) { showError(error.message); }
  finally { setBusy(false); }
}
async function removeApp() {
  if (busy) return;
  setBusy(true);
  try {
    apps = await request({action:'delete',id:Number(form.elements.id.value)});
    $('#delete-dialog').close(); editor.close(); render();
  } catch (error) {
    $('#delete-error').textContent = error.message;
    $('#delete-error').hidden = false;
  } finally { setBusy(false); }
}
async function saveOrder(ids, focusId) {
  if (busy) return;
  const previous = apps;
  apps = ids.map(id => apps.find(app => app.id === id));
  setBusy(true);
  render();
  setBusy(true);
  try { apps = await request({action:'reorder',ids}); }
  catch (error) { apps = previous; notify(error.message); }
  finally {
    render(); setBusy(false);
    if (focusId) $(`[data-id="${focusId}"] .drag-handle`)?.focus();
  }
}
function moveApp(id, offset) {
  if (busy || drag) return;
  const ids = apps.map(app => app.id);
  const index = ids.indexOf(id), target = index + offset;
  if (index < 0 || target < 0 || target >= ids.length) return;
  [ids[index], ids[target]] = [ids[target], ids[index]];
  saveOrder(ids,id);
}

// Pointer handles work with mouse, pen, and touch. Only a completed drop writes order.
$('#apps').addEventListener('pointerdown', event => {
  const handle = event.target.closest('.drag-handle');
  if (!handle || !editing || busy || event.button !== 0) return;
  event.preventDefault();
  const card = handle.closest('.app-card');
  drag = {id:Number(card.dataset.id), pointer:event.pointerId, handle, card, startX:event.clientX, startY:event.clientY, moved:false};
  handle.setPointerCapture(event.pointerId);
});
document.addEventListener('pointermove', event => {
  if (!drag || drag.pointer !== event.pointerId) return;
  if (!drag.moved && Math.hypot(event.clientX - drag.startX,event.clientY - drag.startY) < 6) return;
  drag.moved = true;
  drag.card.classList.add('dragging');
  document.body.classList.add('drag-active');
  const target = document.elementFromPoint(event.clientX,event.clientY)?.closest('.app-card');
  if (target && target !== drag.card) {
    const cards = $$('.app-card');
    if (cards.indexOf(target) > cards.indexOf(drag.card)) target.after(drag.card);
    else target.before(drag.card);
  }
  if (event.clientY < 60) window.scrollBy(0,-18);
  else if (event.clientY > innerHeight - 60) window.scrollBy(0,18);
});
function finishDrag(cancel = false) {
  if (!drag) return;
  const current = drag;
  drag = null;
  if (current.handle.hasPointerCapture(current.pointer)) current.handle.releasePointerCapture(current.pointer);
  document.body.classList.remove('drag-active');
  const ids = $$('.app-card').map(card => Number(card.dataset.id));
  if (!cancel && current.moved && ids.some((id,index) => id !== apps[index].id)) saveOrder(ids,current.id);
  else render();
}
document.addEventListener('pointerup', event => { if (drag?.pointer === event.pointerId) finishDrag(); });
document.addEventListener('pointercancel', () => finishDrag(true));
document.addEventListener('keydown', event => { if (event.key === 'Escape' && drag) {event.preventDefault();finishDrag(true);} });

$('#arrange').onclick = () => { if (!busy) {editing = !editing;render();} };
document.addEventListener('click', event => {
  const target = event.target.closest('button,a');
  if (!target || busy) return;
  if (target.hasAttribute('data-add')) openEditor();
  if (target.dataset.edit) openEditor(Number(target.dataset.edit));
  if (target.dataset.move) moveApp(Number(target.dataset.app),Number(target.dataset.move));
  if (target.dataset.logo) { $('#logo-url').value = ''; chooseLogo(target.dataset.logo); }
  if (editing && target.classList.contains('app-link')) {event.preventDefault();openEditor(Number(target.closest('.app-card').dataset.id));}
});
$('#close-editor').onclick = $('#cancel-editor').onclick = () => { if (!busy && !uploading) editor.close(); };
form.onsubmit = save;
$('#delete-app').onclick = () => {
  $('#delete-name').textContent = form.elements.name.value;
  $('#delete-error').hidden = true;
  $('#delete-dialog').showModal();
};
$('#cancel-delete').onclick = () => { if (!busy) $('#delete-dialog').close(); };
$('#confirm-delete').onclick = removeApp;
for (const dialog of [editor,$('#delete-dialog')]) {
  dialog.addEventListener('cancel', event => { if (busy || uploading) event.preventDefault(); });
  dialog.addEventListener('click', event => {
    if (event.target !== dialog || busy || uploading) return;
    const bounds = dialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) dialog.close();
  });
}
form.elements.address.addEventListener('blur', previewLogo);
$('#logo-url').addEventListener('change', () => chooseLogo($('#logo-url').value.trim() || 'auto'));
$('#auto-logo').onclick = () => { $('#logo-url').value = ''; chooseLogo('auto'); };
$('#upload-logo').onclick = () => $('#logo-file').click();
$('#logo-file').onchange = async event => {
  const file = event.target.files[0];
  if (!file) return;
  if (!['image/png','image/jpeg','image/webp'].includes(file.type) || file.size > 5_000_000) {
    showError('Choose a PNG, JPEG, or WebP under 5 MB.');
    $('#logo-file').value = ''; return;
  }
  uploading = true; setBusy(true);
  try {
    const bitmap = await createImageBitmap(file);
    const ratio = Math.min(1,128 / Math.max(bitmap.width,bitmap.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1,Math.round(bitmap.width * ratio));
    canvas.height = Math.max(1,Math.round(bitmap.height * ratio));
    canvas.getContext('2d').drawImage(bitmap,0,0,canvas.width,canvas.height);
    bitmap.close();
    const data = canvas.toDataURL('image/webp',.85);
    if (data.length > 48_000) throw new Error('Try a simpler logo.');
    $('#logo-url').value = ''; chooseLogo(data); $('#form-error').hidden = true;
  } catch { showError('Could not read this image. Try another.'); }
  finally { uploading = false; setBusy(false); $('#logo-file').value = ''; }
};
document.addEventListener('error', event => {
  if (event.target instanceof HTMLImageElement && !event.target.src.includes('/icons/server.svg')) event.target.src = localLogo('server');
},true);
async function init() {
  try { apps = await request(); render(); }
  catch { $('#load-error').hidden = false; $$('button').forEach(button => button.disabled = true); }
}
init();
