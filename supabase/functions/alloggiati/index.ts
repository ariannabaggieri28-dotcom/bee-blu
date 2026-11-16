// Bee&blu – collegamento al servizio web Alloggiati Web (Polizia di Stato).
// Azioni:
//  - "stato" (predefinita): verifica le credenziali e scarica le tabelle ufficiali dei codici.
//  - "controlla" {prenotazione_id}: costruisce le schedine e le fa validare dal servizio Test
//    della Polizia. NON registra nulla in Questura.
//  - "invia" {prenotazione_id, conferma: true}: invio vero (Send). Bloccato finché
//    impostazioni.alloggiati.invio_attivo non è true.
//  - "automatico": lanciato ogni ora da pg_cron. Invia i check-in completati con arrivo oggi
//    (dopo le 15, ora di Roma) o ieri, e registra in "controlli" chi è arrivato senza check-in.
// Chiamata protetta: ?k= uguale a impostazioni.smoobu.token_webhook.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const URL_WS = 'https://alloggiatiweb.poliziadistato.it/service/service.asmx';
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { 'Content-Type': 'application/json' } });
const esc = (s: string) => s.replace(/[<>&'"]/g, (c) => ({ '<': '&lt;', '>': '&gt;', '&': '&amp;', "'": '&apos;', '"': '&quot;' }[c]!));
const tag = (xml: string, nome: string) => xml.match(new RegExp(`<${nome}>([\\s\\S]*?)</${nome}>`))?.[1] ?? null;
const unesc = (s: string) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');

// Credenziali dai secrets: nomi standard, con ripiego su altri nomi che contengono "ALLOGGIATI"
function credenziali() {
  const env = Deno.env.toObject();
  const nomi = Object.keys(env).filter((k) => /alloggiati/i.test(k));
  const trova = (re: RegExp) => nomi.find((k) => re.test(k));
  const kUtente = trova(/utente|user/i);
  const kPassword = trova(/pass/i);
  const kWskey = trova(/wskey|ws_key|key|chiave/i) ?? nomi.find((k) => k !== kUtente && k !== kPassword);
  return {
    nomi,
    utente: kUtente ? env[kUtente].trim() : '',
    password: kPassword ? env[kPassword] : '',
    wskey: kWskey ? env[kWskey].trim() : '',
    usati: { utente: kUtente ?? null, password: kPassword ?? null, wskey: kWskey ?? null },
  };
}

async function soap(azione: string, corpo: string) {
  const env = `<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body><${azione} xmlns="AlloggiatiService">${corpo}</${azione}></soap:Body></soap:Envelope>`;
  const r = await fetch(URL_WS, { method: 'POST', headers: { 'Content-Type': 'text/xml; charset=utf-8', SOAPAction: `AlloggiatiService/${azione}` }, body: env });
  return { stato: r.status, xml: await r.text() };
}
const esito = (xml: string) => ({
  ok: tag(xml, 'esito') === 'true',
  codice: tag(xml, 'ErroreCod'),
  errore: tag(xml, 'ErroreDes'),
  dettaglio: tag(xml, 'ErroreDettaglio'),
});

async function token(c: ReturnType<typeof credenziali>) {
  const r = await soap('GenerateToken', `<Utente>${esc(c.utente)}</Utente><Password>${esc(c.password)}</Password><WsKey>${esc(c.wskey)}</WsKey>`);
  return { token: tag(r.xml, 'token'), esito: esito(r.xml), http: r.stato };
}

async function tabella(c: ReturnType<typeof credenziali>, tk: string, tipo: string) {
  const r = await soap('Tabella', `<Utente>${esc(c.utente)}</Utente><token>${esc(tk)}</token><tipo>${tipo}</tipo>`);
  const csv = tag(r.xml, 'CSV');
  return { esito: esito(r.xml), righe: csv ? unesc(csv).split(/\r?\n/).filter((l) => l.trim()) : [] };
}

// Esiti per singola schedina restituiti da Test/Send
function esitiSchedine(xml: string) {
  const blocco = tag(xml, 'Dettaglio') ?? '';
  return [...blocco.matchAll(/<EsitoOperazioneServizio>([\s\S]*?)<\/EsitoOperazioneServizio>/g)].map((m) => esito(m[1]));
}

async function schedine(c: ReturnType<typeof credenziali>, tk: string, prenotazioneId: string, modalita: 'controllo' | 'invio', debug = false) {
  const { data: righe, error } = await sb.rpc('schedine_prenotazione', { p_id: prenotazioneId });
  if (error) return json({ errore: 'costruzione', dettaglio: error.message }, 500);
  if (!righe?.length) return json({ errore: 'nessun_ospite' }, 404);
  const problemi = righe.filter((r: { problemi: string[] }) => r.problemi.length);
  if (problemi.length) {
    // Dati da correggere: non si chiama nemmeno il servizio
    await sb.from('invii_alloggiati').insert({ prenotazione_id: prenotazioneId, modalita, schedine_valide: 0, esito: { fase: 'conversione', righe } });
    if (modalita === 'invio') await sb.from('prenotazioni').update({ stato: 'errore' }).eq('id', prenotazioneId);
    return json({ ok: false, fase: 'conversione', problemi: problemi.map((r: { ordine: number; problemi: string[] }) => ({ ospite: r.ordine + 1, problemi: r.problemi })) });
  }
  const elenco = righe.map((r: { record: string }) => `<string>${esc(r.record)}</string>`).join('');
  const azione = modalita === 'invio' ? 'Send' : 'Test';
  const r = await soap(azione, `<Utente>${esc(c.utente)}</Utente><token>${esc(tk)}</token><ElencoSchedine>${elenco}</ElencoSchedine>`);
  const generale = esito(r.xml);
  const valide = Number(tag(r.xml, 'SchedineValide') ?? 0);
  const perRiga = esitiSchedine(r.xml);
  const ok = generale.ok && valide === righe.length;
  const registro = { fase: 'servizio', azione, http: r.stato, generale, valide, per_riga: perRiga, righe: righe.map((x: { ordine: number; dettagli: unknown }) => ({ ordine: x.ordine, dettagli: x.dettagli })) };
  await sb.from('invii_alloggiati').insert({ prenotazione_id: prenotazioneId, modalita, schedine_valide: valide, esito: registro });
  if (modalita === 'invio') await sb.from('prenotazioni').update({ stato: ok ? 'inviato' : 'errore' }).eq('id', prenotazioneId);
  return json({ ok, azione, valide, totale: righe.length, generale, per_riga: perRiga, http: r.stato, risposta: ok && !debug ? undefined : r.xml.slice(0, 3000) });
}

Deno.serve(async (req) => {
  const { data: imp } = await sb.from('impostazioni').select('valore').eq('chiave', 'smoobu').single();
  if (new URL(req.url).searchParams.get('k') !== imp?.valore?.token_webhook) return json({ errore: 'non_autorizzato' }, 401);
  let corpo: Record<string, unknown> = {};
  if (req.method === 'POST') { try { corpo = await req.json(); } catch { /* corpo vuoto */ } }
  const azione = String(corpo.azione ?? 'stato');

  const c = credenziali();
  const mancano = [!c.utente && 'utente', !c.password && 'password', !c.wskey && 'wskey'].filter(Boolean);
  if (mancano.length) return json({ errore: 'credenziali_mancanti', mancano, secrets_trovati: c.nomi });

  const t = await token(c);
  if (!t.token) return json({ errore: 'token', esito: t.esito, http: t.http, secrets_usati: c.usati });

  if (azione === 'automatico') {
    const { data: cfg } = await sb.from('impostazioni').select('valore').eq('chiave', 'alloggiati').maybeSingle();
    if (cfg?.valore?.invio_attivo !== true) return json({ ok: true, saltato: 'invio_non_attivo' });
    const roma = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Rome', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', hourCycle: 'h23' }).formatToParts(new Date());
    const v = (t: string) => roma.find((x) => x.type === t)!.value;
    const oggi = `${v('year')}-${v('month')}-${v('day')}`, ora = Number(v('hour'));
    const d = new Date(oggi + 'T12:00:00Z'); d.setUTCDate(d.getUTCDate() - 1);
    const ieri = d.toISOString().slice(0, 10);
    const date = ora >= 15 ? [oggi, ieri] : [ieri];
    const { data: pren } = await sb.from('prenotazioni').select('id,codice_canale,titolare,data_arrivo,stato')
      .in('data_arrivo', date).in('stato', ['check_in_completato', 'in_attesa', 'errore']);
    const esiti = [];
    for (const p of pren ?? []) {
      if (p.stato === 'in_attesa') {
        if (p.data_arrivo === oggi && ora < 21) { esiti.push({ id: p.id, esito: 'in_attesa_checkin' }); continue; } // può ancora farlo in giornata
        // Nessun check-in online: va fatto a mano entro 24 ore dall'arrivo
        await sb.from('controlli').upsert({ chiave: `senza_checkin:${p.id}`, prenotazione_id: p.id, tipo: 'senza_checkin',
          messaggio: `${p.titolare} (${p.codice_canale}) arrivato il ${p.data_arrivo} senza check-in online: registrare a mano su Alloggiati Web entro 24 ore.` }, { onConflict: 'chiave', ignoreDuplicates: true });
        esiti.push({ id: p.id, esito: 'senza_checkin' });
        continue;
      }
      if (p.stato === 'errore') {
        // ritenta solo se nel frattempo l'ospite ha corretto i dati (ultimo invio più vecchio dell'ultima modifica)
        const { data: ult } = await sb.from('invii_alloggiati').select('creato_il').eq('prenotazione_id', p.id).order('creato_il', { ascending: false }).limit(1);
        const { data: mod } = await sb.from('ospiti').select('creato_il').eq('prenotazione_id', p.id).order('creato_il', { ascending: false }).limit(1);
        if (ult?.[0] && mod?.[0] && mod[0].creato_il <= ult[0].creato_il) { esiti.push({ id: p.id, esito: 'errore_in_attesa_correzione' }); continue; }
      }
      const r = await schedine(c, t.token, p.id, 'invio');
      const corpoR = await r.json();
      if (!corpoR.ok) {
        await sb.from('controlli').upsert({ chiave: `invio_fallito:${p.id}:${oggi}`, prenotazione_id: p.id, tipo: 'invio_fallito',
          messaggio: `Invio in Questura NON riuscito per ${p.titolare} (${p.codice_canale}): ${JSON.stringify(corpoR.problemi ?? corpoR.per_riga ?? corpoR.generale)}` }, { onConflict: 'chiave', ignoreDuplicates: true });
      }
      esiti.push({ id: p.id, esito: corpoR.ok ? 'inviato' : 'errore' });
    }
    await sb.from('impostazioni').upsert({ chiave: 'ultimo_giro_alloggiati', valore: { quando: new Date().toISOString(), esiti } });
    return json({ ok: true, date, esiti });
  }

  if (azione === 'controlla' || azione === 'invia') {
    const id = String(corpo.prenotazione_id ?? '');
    if (!/^[0-9a-f-]{36}$/.test(id)) return json({ errore: 'prenotazione_id' }, 400);
    if (azione === 'invia') {
      const { data: cfg } = await sb.from('impostazioni').select('valore').eq('chiave', 'alloggiati').maybeSingle();
      if (cfg?.valore?.invio_attivo !== true || corpo.conferma !== true) return json({ errore: 'invio_non_attivo' }, 403);
    }
    return schedine(c, t.token, id, azione === 'invia' ? 'invio' : 'controllo', corpo.debug === true);
  }

  const auth = await soap('Authentication_Test', `<Utente>${esc(c.utente)}</Utente><token>${esc(t.token)}</token>`);

  // Tabelle dei codici
  const luoghi = await tabella(c, t.token, 'Luoghi');
  const documenti = await tabella(c, t.token, 'Tipi_Documento');
  const appartamenti = await tabella(c, t.token, 'ListaAppartamenti');

  const righeLuoghi = luoghi.righe
    .map((l) => l.split(';').map((x) => x.trim()))
    .filter((p) => /^\d+$/.test(p[0] ?? ''))
    .map((p) => ({ codice: p[0], descrizione: p[1] ?? '', provincia: p[2] || null, cessato: !!(p[3] && p[3].length) }));
  const righeDoc = documenti.righe
    .map((l) => l.split(';').map((x) => x.trim()))
    .filter((p) => p[0] && !/^codice$/i.test(p[0]))
    .map((p) => ({ codice: p[0], descrizione: p[1] ?? '' }));

  let salvati = { luoghi: 0, documenti: 0 };
  for (let i = 0; i < righeLuoghi.length; i += 1000) {
    const { error } = await sb.from('luoghi').upsert(righeLuoghi.slice(i, i + 1000), { onConflict: 'codice' });
    if (error) return json({ errore: 'salvataggio_luoghi', dettaglio: error.message });
  }
  salvati.luoghi = righeLuoghi.length;
  if (righeDoc.length) {
    const { error } = await sb.from('tipi_documento').upsert(righeDoc, { onConflict: 'codice' });
    if (error) return json({ errore: 'salvataggio_documenti', dettaglio: error.message });
    salvati.documenti = righeDoc.length;
  }

  return json({
    ok: true,
    secrets_usati: c.usati,
    autenticazione: esito(auth.xml),
    tabelle: { luoghi: luoghi.esito, documenti: documenti.esito, appartamenti: appartamenti.esito },
    esempio_luoghi: luoghi.righe.slice(0, 2),
    esempio_documenti: documenti.righe.slice(0, 3),
    appartamenti: appartamenti.righe.slice(0, 5),
    salvati,
  });
});
