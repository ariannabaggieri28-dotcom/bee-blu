// Bee&blu – riceve i webhook di Smoobu (nuova, modificata, cancellata, eliminata)
// e tiene allineata la tabella prenotazioni. Smoobu non firma i webhook:
// l'URL contiene un token segreto (?k=...) salvato in impostazioni.smoobu.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false },
});
const json = (c: unknown, s = 200) => new Response(JSON.stringify(c), { status: s, headers: { 'Content-Type': 'application/json' } });

const giorni = (a: string, b: string) => Math.round((Date.parse(b + 'T12:00:00Z') - Date.parse(a + 'T12:00:00Z')) / 864e5);
const canale = (n: unknown) => {
  const s = String(n ?? '').toLowerCase();
  if (s.includes('airbnb')) return 'airbnb';
  // "Direct booking" contiene "booking": le dirette vanno riconosciute prima di Booking.com
  if (s.includes('direct') || s.includes('homepage') || s.includes('smoobu') || s.includes('diretta')) return 'diretta';
  if (s.includes('booking')) return 'booking';
  return 'altro';
};
const t = (v: unknown, max: number) => String(v ?? '').replace(/\s+/g, ' ').trim().slice(0, max) || null;

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ ok: true });

  const { data: imp } = await sb.from('impostazioni').select('valore').eq('chiave', 'smoobu').single();
  const atteso = imp?.valore?.token_webhook;
  const k = new URL(req.url).searchParams.get('k');
  if (!atteso || k !== atteso) return json({ errore: 'non_autorizzato' }, 401);

  let corpo: any;
  try { corpo = await req.json(); } catch { return json({ errore: 'richiesta' }, 400); }
  const azione = String(corpo?.action ?? '');
  const d = corpo?.data ?? {};
  const smoobuId = Number(d.id);

  const prenotazione = ['newReservation', 'updateReservation', 'cancelReservation', 'deleteReservation'].includes(azione);
  if (prenotazione) {
    // teniamo anche l'elenco dei campi ricevuti (non i valori) per verificare cosa manda Smoobu
    await sb.from('impostazioni').update({ valore: { ...imp!.valore, ultimo_evento: { azione, id: smoobuId || null, il: new Date().toISOString(), campi: Object.keys(d).slice(0, 80) } }, aggiornato_il: new Date().toISOString() }).eq('chiave', 'smoobu');
  }
  if (!prenotazione) return json({ ok: true, ignorato: azione });
  if (!smoobuId) return json({ ok: true, ignorato: 'senza_id' });

  if (azione === 'cancelReservation' || azione === 'deleteReservation' || d.type === 'cancellation') {
    await sb.from('prenotazioni').update({ stato: 'annullata', aggiornato_il: new Date().toISOString() }).eq('smoobu_id', smoobuId);
    return json({ ok: true, stato: 'annullata' });
  }
  // Blocchi del calendario: non sono ospiti
  if (d['is-blocked-booking']) return json({ ok: true, ignorato: 'blocco' });

  const arrivo = String(d.arrival ?? '');
  const partenza = String(d.departure ?? '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(arrivo) || !/^\d{4}-\d{2}-\d{2}$/.test(partenza)) return json({ errore: 'date' }, 400);
  const notti = Math.min(30, Math.max(1, giorni(arrivo, partenza)));
  const ospiti = Math.min(20, Math.max(1, (Number(d.adults) || 0) + (Number(d.children) || 0)));
  const nome = t(d['guest-name'], 120) ?? t([d.firstname, d.lastname].filter(Boolean).join(' '), 120) ?? 'Ospite';

  const { data: app } = await sb.from('appartamenti').select('id').order('creato_il').limit(1).single();

  const riga = {
    smoobu_id: smoobuId,
    appartamento_id: app?.id ?? null,
    canale: canale(d.channel?.name),
    codice_canale: t(d['reference-id'], 64) ?? String(smoobuId),
    titolare: nome,
    email: t(d.email, 200),
    telefono: t(d.phone, 40),
    data_arrivo: arrivo,
    notti,
    ospiti_attesi: ospiti,
    lingua: t(d.language, 10),
    // "Istruzioni per l'assistente" di Smoobu: lì Arianna scrive il codice del tastierino
    note_assistente: t(d['assistant-notice'] ?? d.assistantNotice ?? d['assistant_notice'], 500),
    aggiornato_il: new Date().toISOString(),
  };

  const { data: esiste } = await sb.from('prenotazioni').select('id,stato').eq('smoobu_id', smoobuId).maybeSingle();
  if (esiste) {
    const agg: Record<string, unknown> = { ...riga };
    // Una prenotazione annullata che torna attiva riparte da capo; le altre tengono il loro stato di check-in
    if (esiste.stato === 'annullata') agg.stato = 'in_attesa';
    const { error } = await sb.from('prenotazioni').update(agg).eq('id', esiste.id);
    if (error) return json({ errore: 'salvataggio', dettaglio: error.message }, 500);
    return json({ ok: true, aggiornata: esiste.id });
  }
  const { data: nuova, error } = await sb.from('prenotazioni').insert(riga).select('id').single();
  if (error) return json({ errore: 'salvataggio', dettaglio: error.message }, 500);
  return json({ ok: true, creata: nuova.id });
});
