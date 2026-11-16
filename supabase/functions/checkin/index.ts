// Bee&blu – check-in online degli ospiti.
// Funzione pubblica: l'ospite non ha un account, viene riconosciuto dal codice della prenotazione.
// Usa la chiave di servizio solo lato server; restituisce all'ospite il minimo indispensabile.
// Azioni: "cerca" (dati prenotazione), "verifica" (controllo di un ospite mentre compila),
// "completa" (salva ospiti e foto del documento). Le foto restano nel bucket privato "documenti":
// non vengono mai cancellate, anche se l'ospite rifà il check-in (restano nello storico).
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const risposta = (corpo: unknown, stato = 200) =>
  new Response(JSON.stringify(corpo), { status: stato, headers: { ...CORS, 'Content-Type': 'application/json' } });

const oggiIso = () => new Date().toISOString().slice(0, 10);
const piuGiorni = (iso: string, n: number) => {
  const d = new Date(iso + 'T12:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};

type Prenotazione = {
  id: string; titolare: string; data_arrivo: string; notti: number; ospiti_attesi: number;
  tipo_gruppo: string; stato: string;
};

async function trova(codiceGrezzo: unknown): Promise<Prenotazione | null> {
  const codice = String(codiceGrezzo ?? '').trim();
  // Solo lettere, numeri e trattini: niente caratteri che possano alterare il filtro.
  if (!/^[A-Za-z0-9-]{6,64}$/.test(codice)) return null;
  const { data, error } = await sb
    .from('prenotazioni')
    .select('id,titolare,data_arrivo,notti,ospiti_attesi,tipo_gruppo,stato')
    .or(`token_checkin.eq.${codice.toLowerCase()},codice_canale.ilike.${codice}`)
    .neq('stato', 'annullata')
    .order('data_arrivo', { ascending: true });
  if (error || !data?.length) return null;
  // La prima prenotazione non ancora conclusa
  const oggi = oggiIso();
  return (data as Prenotazione[]).find((p) => piuGiorni(p.data_arrivo, p.notti) >= oggi) ?? null;
}

const testo = (v: unknown, max: number) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, max);
const dataValida = (v: unknown) => {
  const s = String(v ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(s + 'T12:00:00Z');
  return !isNaN(d.getTime()) && s <= oggiIso() && s >= '1900-01-01';
};

type Messaggio = { campo: string; livello: 'errore' | 'avviso'; it: string; en: string; suggerito?: string; opzioni?: string[] };

async function verifica(o: Record<string, unknown>, titolare: boolean): Promise<Messaggio[]> {
  const dati = {
    nome: testo(o.nome, 60), cognome: testo(o.cognome, 80), nascita: testo(o.nascita, 10), nato: testo(o.nato, 60),
    comune: testo(o.comune, 60), citt: testo(o.citt, 60), res: testo(o.res, 60), resLoc: o.resItalia === false ? '' : testo(o.resLoc, 60),
    tdoc: testo(o.tdoc, 5), ndoc: testo(o.ndoc, 30), rilascio: testo(o.rilascio, 60),
  };
  const { data, error } = await sb.rpc('verifica_ospite', { o: dati, titolare });
  if (error) throw error;
  return (data ?? []) as Messaggio[];
}

// --- Foto del documento: formato, peso e dimensioni controllati anche qui, non solo nel browser
const MIN_BYTE = 40 * 1024, MAX_BYTE = 8 * 1024 * 1024, MIN_LATO = 900;
function tipoImmagine(b: Uint8Array): string | null {
  if (b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'jpg';
  if (b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47) return 'png';
  if (String.fromCharCode(...b.slice(0, 4)) === 'RIFF' && String.fromCharCode(...b.slice(8, 12)) === 'WEBP') return 'webp';
  const ftyp = String.fromCharCode(...b.slice(4, 12));
  if (/^ftyp(heic|heix|mif1|msf1)/.test(ftyp)) return 'heic';
  return null;
}
function latoJpeg(b: Uint8Array): number | null {
  let i = 2;
  while (i + 9 < b.length) {
    if (b[i] !== 0xff) { i++; continue; }
    const m = b[i + 1];
    if (m >= 0xc0 && m <= 0xcf && m !== 0xc4 && m !== 0xc8 && m !== 0xcc) {
      const h = (b[i + 5] << 8) | b[i + 6], w = (b[i + 7] << 8) | b[i + 8];
      return Math.max(w, h);
    }
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return null;
}
function leggiFoto(v: unknown): { bytes: Uint8Array; est: string; mime: string } | { errore: string } | null {
  const s = typeof v === 'string' ? v : '';
  if (!s) return null;
  const m = s.match(/^data:([a-z/+.-]+);base64,(.+)$/);
  if (!m) return { errore: 'foto_formato' };
  const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
  const est = tipoImmagine(bytes);
  if (!est) return { errore: 'foto_formato' };
  if (bytes.length > MAX_BYTE) return { errore: 'foto_grande' };
  if (bytes.length < MIN_BYTE) return { errore: 'foto_piccola' };
  if (est === 'jpg') { const l = latoJpeg(bytes); if (l !== null && l < MIN_LATO) return { errore: 'foto_piccola' }; }
  const mime = { jpg: 'image/jpeg', png: 'image/png', webp: 'image/webp', heic: 'image/heic' }[est]!;
  return { bytes, est, mime };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return risposta({ errore: 'metodo' }, 405);

  let corpo: Record<string, unknown>;
  try { corpo = await req.json(); } catch { return risposta({ errore: 'richiesta' }, 400); }

  const p = await trova(corpo.codice);
  if (!p) return risposta({ errore: 'non_trovata' }, 404);

  if (corpo.azione === 'cerca') {
    return risposta({
      nome: p.titolare.split(' ')[0],
      arrivo: p.data_arrivo,
      notti: p.notti,
      ospiti: p.ospiti_attesi,
      tipo_gruppo: p.tipo_gruppo,
      completato: p.stato !== 'in_attesa',
      bloccato: p.stato === 'inviato',
    });
  }

  // Controllo di un singolo ospite mentre compila: non salva nulla
  if (corpo.azione === 'verifica') {
    const o = (corpo.ospite ?? {}) as Record<string, unknown>;
    try { return risposta({ messaggi: await verifica(o, corpo.indice === 0) }); }
    catch { return risposta({ messaggi: [] }); } // in caso di guasto non blocchiamo l'ospite: ricontrolliamo al salvataggio
  }

  if (corpo.azione !== 'completa') return risposta({ errore: 'azione' }, 400);
  if (p.stato === 'inviato') return risposta({ errore: 'gia_registrato' }, 409);

  const ospiti = Array.isArray(corpo.ospiti) ? corpo.ospiti as Record<string, unknown>[] : [];
  if (ospiti.length < 1 || ospiti.length > 20) return risposta({ errore: 'ospiti' }, 400);

  const righe = [];
  for (const [i, o] of ospiti.entries()) {
    const titolare = i === 0;
    const r = {
      prenotazione_id: p.id,
      ordine: i,
      nome: testo(o.nome, 30),
      cognome: testo(o.cognome, 50),
      sesso: o.sesso === 'M' || o.sesso === 'F' ? o.sesso : null,
      data_nascita: dataValida(o.nascita) ? String(o.nascita) : null,
      stato_nascita: testo(o.nato, 60),
      comune_nascita: testo(o.comune, 60) || null,
      cittadinanza: testo(o.citt, 60),
      residenza_stato: testo(o.res, 60),
      residenza_comune: o.resItalia ? testo(o.resLoc, 60) : null,
      residenza_localita: o.resItalia ? null : (testo(o.resLoc, 30) || null),
      tipo_documento: titolare ? testo(o.tdoc, 5) : null,
      numero_documento: titolare ? testo(o.ndoc, 30).toUpperCase().replace(/[^A-Z0-9]/g, '') : null,
      luogo_rilascio: titolare ? testo(o.rilascio, 60) : null,
      // tutte le righe devono avere le stesse colonne (insert multiplo)
      foto_documento_path: null as string | null, foto_retro_path: null as string | null, foto_storico: [] as string[],
    };
    const manca = !r.nome || !r.cognome || !r.sesso || !r.data_nascita || !r.stato_nascita || !r.cittadinanza || !r.residenza_stato
      || (titolare && (!r.numero_documento || !r.luogo_rilascio || !r.tipo_documento));
    if (manca) return risposta({ errore: 'campi', ospite: i + 1 }, 400);
    // Stessi controlli fatti durante la compilazione: gli errori bloccano, gli avvisi no
    let msg: Messaggio[] = [];
    try { msg = await verifica(o, titolare); } catch { return risposta({ errore: 'salvataggio' }, 500); }
    const errori = msg.filter((m) => m.livello === 'errore');
    if (errori.length) return risposta({ errore: 'campi', ospite: i + 1, messaggi: errori }, 400);
    righe.push(r);
  }

  // Foto del documento del titolare: obbligatoria la prima (fronte o pagina del passaporto),
  // il retro per carta d'identità e patente.
  const fronte = leggiFoto(corpo.foto);
  const retro = leggiFoto(corpo.foto_retro);
  const serveRetro = ['IDENT', 'IDELE', 'PATEN'].includes(String(righe[0].tipo_documento));
  const { data: vecchie } = await sb.from('ospiti').select('foto_documento_path,foto_retro_path,foto_storico').eq('prenotazione_id', p.id).eq('ordine', 0);
  const prec = vecchie?.[0];
  if (fronte && 'errore' in fronte) return risposta({ errore: fronte.errore, lato: 'fronte' }, 400);
  if (retro && 'errore' in retro) return risposta({ errore: retro.errore, lato: 'retro' }, 400);
  if (!fronte && !prec?.foto_documento_path) return risposta({ errore: 'foto_mancante', lato: 'fronte' }, 400);
  if (serveRetro && !retro && !prec?.foto_retro_path) return risposta({ errore: 'foto_mancante', lato: 'retro' }, 400);

  const carica = async (f: { bytes: Uint8Array; est: string; mime: string }, lato: string) => {
    const percorso = `${p.id}/documento-${lato}-${Date.now()}.${f.est}`;
    const { error } = await sb.storage.from('documenti').upload(percorso, f.bytes, { contentType: f.mime, upsert: false });
    if (error) throw error;
    return percorso;
  };
  let pathFronte = prec?.foto_documento_path ?? null, pathRetro = serveRetro ? (prec?.foto_retro_path ?? null) : null;
  const storico: string[] = [...(prec?.foto_storico ?? [])];
  try {
    if (fronte) { if (pathFronte) storico.push(pathFronte); pathFronte = await carica(fronte as { bytes: Uint8Array; est: string; mime: string }, 'fronte'); }
    if (retro) { if (prec?.foto_retro_path) storico.push(prec.foto_retro_path); pathRetro = await carica(retro as { bytes: Uint8Array; est: string; mime: string }, 'retro'); }
    else if (!serveRetro && prec?.foto_retro_path) storico.push(prec.foto_retro_path);
  } catch { return risposta({ errore: 'salvataggio' }, 500); }
  righe[0] = { ...righe[0], foto_documento_path: pathFronte, foto_retro_path: pathRetro, foto_storico: [...new Set(storico)] };

  // Un nuovo invio sostituisce i dati precedenti (l'ospite può correggere fino all'invio in Questura).
  // Le foto vecchie NON vengono cancellate: restano nel bucket e nello storico.
  const { error: errDel } = await sb.from('ospiti').delete().eq('prenotazione_id', p.id);
  if (errDel) return risposta({ errore: 'salvataggio' }, 500);
  const { error: errIns } = await sb.from('ospiti').insert(righe);
  if (errIns) return risposta({ errore: 'salvataggio', dettaglio: errIns.message }, 500);

  const tipo = corpo.tipo_gruppo === 'gruppo' ? 'gruppo' : 'famiglia';
  await sb.from('prenotazioni').update({ stato: 'check_in_completato', tipo_gruppo: tipo }).eq('id', p.id);

  return risposta({ ok: true });
});
