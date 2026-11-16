-- Bee&blu – verifica "intelligente" dei dati di un ospite mentre compila il check-in.
-- Restituisce un elenco di messaggi per campo (errore = blocca, avviso = consiglio) in IT e EN,
-- con eventuali opzioni cliccabili (omonimi) o un suggerimento ("Intendevi Germania?").

alter table public.ospiti add column if not exists foto_retro_path text;
alter table public.ospiti add column if not exists foto_storico text[] not null default '{}';

-- Paesi per cui la carta d'identità è un documento valido per viaggiare (UE/SEE, Svizzera, microstati)
create table if not exists public.stati_carta_identita (descrizione text primary key);
alter table public.stati_carta_identita enable row level security;
insert into public.stati_carta_identita values
 ('ITALIA'),('AUSTRIA'),('BELGIO'),('BULGARIA'),('CIPRO'),('CROAZIA'),('DANIMARCA'),('ESTONIA'),('FINLANDIA'),('FRANCIA'),('GERMANIA'),('GRECIA'),
 ('IRLANDA'),('LETTONIA'),('LITUANIA'),('LUSSEMBURGO'),('MALTA'),('PAESI BASSI'),('POLONIA'),('PORTOGALLO'),('REPUBBLICA CECA'),('ROMANIA'),
 ('REPUBBLICA SLOVACCA'),('SLOVENIA'),('SPAGNA'),('SVEZIA'),('UNGHERIA'),('ISLANDA'),('LIECHTENSTEIN'),('NORVEGIA'),('SVIZZERA'),('SAN MARINO'),
 ('STATO DELLA CITTA'' DEL VATICANO'),('MONACO'),('PRINCIPATO DI MONACO'),('ANDORRA')
on conflict do nothing;

create or replace function public.verifica_ospite(o jsonb, titolare boolean)
returns jsonb
language plpgsql stable set search_path = public, extensions as $$
declare
  out jsonb := '[]'::jsonb;
  v text; n text; s record; c record; ct record; ril_s record; ril_c record;
  nascita date; eta int; tdoc text := coalesce(o->>'tdoc', ''); ndoc text;
  italiano boolean; carta_ok boolean;
begin
  -- i record vanno inizializzati: un record mai assegnato non si può leggere
  select null::text codice, null::text descrizione, null::text provincia, null::text metodo into s;
  c := s; ct := s; ril_s := s; ril_c := s;

  -- Nome e cognome: come sul documento, lettere latine, niente trattini, numeri o simboli
  foreach v in array array['nome', 'cognome'] loop
    n := translate(coalesce(o->>v, ''), '’‘`´ʼ', '''''''''''');  -- apostrofi "tipografici" dell'iPhone -> '
    if btrim(n) = '' then continue; end if;
    if n ~ '-' then
      out := out || jsonb_build_object('campo', v, 'livello', 'errore',
        'it', 'Niente trattini: al loro posto metti uno spazio (es. "Rossi Bianchi").',
        'en', 'No hyphens: use a space instead (e.g. "Smith Jones").',
        'suggerito', btrim(regexp_replace(regexp_replace(n, '-', ' ', 'g'), '\s+', ' ', 'g')));
    elsif n ~ '[0-9]' then
      out := out || jsonb_build_object('campo', v, 'livello', 'errore', 'it', 'Il nome non può contenere numeri.', 'en', 'Names cannot contain numbers.');
    elsif upper(extensions.unaccent('extensions.unaccent'::regdictionary, n)) ~ '[^A-Z'' ]' then
      if n ~ '[.,;:/()&_@#*+!?"]' then
        out := out || jsonb_build_object('campo', v, 'livello', 'errore',
          'it', 'Solo lettere, spazi e apostrofo: togli punti, virgole e simboli.',
          'en', 'Only letters, spaces and apostrophes: remove dots, commas and symbols.');
      else
        out := out || jsonb_build_object('campo', v, 'livello', 'errore',
          'it', 'Scrivilo in caratteri latini, come nella riga in basso del passaporto.',
          'en', 'Please use Latin letters, as printed in the bottom lines of your passport.');
      end if;
    elsif length(btrim(n)) < 2 then
      out := out || jsonb_build_object('campo', v, 'livello', 'errore', 'it', 'Scrivilo per intero, come sul documento.', 'en', 'Please write it in full, as on your document.');
    end if;
    if v = 'cognome' and length(btrim(n)) > 50 or v = 'nome' and length(btrim(n)) > 30 then
      out := out || jsonb_build_object('campo', v, 'livello', 'avviso', 'it', 'È molto lungo: verrà accorciato nella registrazione.', 'en', 'Quite long: it will be shortened in the registration.');
    end if;
  end loop;

  -- Data di nascita
  begin nascita := nullif(o->>'nascita', '')::date; exception when others then nascita := null; end;
  if nullif(o->>'nascita', '') is not null and nascita is null then
    out := out || jsonb_build_object('campo', 'nascita', 'livello', 'errore', 'it', 'Data non valida.', 'en', 'Invalid date.');
  elsif nascita is not null then
    eta := extract(year from age(current_date, nascita));
    if nascita > current_date then
      out := out || jsonb_build_object('campo', 'nascita', 'livello', 'errore', 'it', 'La data è nel futuro.', 'en', 'This date is in the future.');
    elsif eta > 110 then
      out := out || jsonb_build_object('campo', 'nascita', 'livello', 'errore', 'it', 'Controlla l''anno di nascita.', 'en', 'Please check the year of birth.');
    elsif titolare and eta < 18 then
      out := out || jsonb_build_object('campo', 'nascita', 'livello', 'avviso',
        'it', 'Chi fa il check-in per primo deve essere un adulto: inserisci prima un adulto del gruppo.',
        'en', 'The first guest should be an adult: please enter an adult of your party first.');
    end if;
  end if;

  -- Paese di nascita (+ comune se Italia)
  if nullif(btrim(o->>'nato'), '') is not null then
    select * into s from public.risolvi_stato(o->>'nato');
    if s.codice is null then
      out := out || case when s.metodo = 'incerto' then
        jsonb_build_object('campo', 'nato', 'livello', 'errore', 'it', 'Paese non riconosciuto. Intendevi ' || initcap(s.descrizione) || '?', 'en', 'Country not recognised. Did you mean ' || initcap(s.descrizione) || '?', 'suggerito', initcap(s.descrizione))
      else jsonb_build_object('campo', 'nato', 'livello', 'errore', 'it', 'Paese non riconosciuto: scegli dall''elenco o scrivilo in italiano o inglese.', 'en', 'Country not recognised: pick from the list or type it in English.') end;
    elsif s.codice = '100000100' and nullif(btrim(o->>'comune'), '') is not null then
      select * into c from public.risolvi_comune(o->>'comune');
      if c.metodo = 'ambiguo' then
        out := out || jsonb_build_object('campo', 'comune', 'livello', 'errore',
          'it', 'Ci sono più comuni con questo nome: scegli quello giusto.', 'en', 'More than one town has this name: please choose.',
          'opzioni', (select jsonb_agg(initcap(x)) from regexp_split_to_table(c.descrizione, ', ') x));
      elsif c.codice is null then
        out := out || case when c.metodo = 'incerto' then
          jsonb_build_object('campo', 'comune', 'livello', 'errore', 'it', 'Comune non trovato. Intendevi ' || initcap(c.descrizione) || '?', 'en', 'Town not found. Did you mean ' || initcap(c.descrizione) || '?', 'suggerito', initcap(c.descrizione))
        else jsonb_build_object('campo', 'comune', 'livello', 'errore', 'it', 'Comune non trovato: scrivi il nome completo del comune italiano.', 'en', 'Town not found: please type the full name of the Italian town.') end;
      end if;
    end if;
  end if;

  -- Cittadinanza
  if nullif(btrim(o->>'citt'), '') is not null then
    select * into ct from public.risolvi_stato(o->>'citt');
    if ct.codice is null then
      out := out || case when ct.metodo = 'incerto' then
        jsonb_build_object('campo', 'citt', 'livello', 'errore', 'it', 'Paese non riconosciuto. Intendevi ' || initcap(ct.descrizione) || '?', 'en', 'Country not recognised. Did you mean ' || initcap(ct.descrizione) || '?', 'suggerito', initcap(ct.descrizione))
      else jsonb_build_object('campo', 'citt', 'livello', 'errore', 'it', 'Paese non riconosciuto: scegli dall''elenco.', 'en', 'Country not recognised: pick from the list.') end;
    end if;
  end if;
  italiano := ct.codice = '100000100';

  -- Residenza (serve per le statistiche ISTAT)
  if nullif(btrim(o->>'res'), '') is not null then
    select * into s from public.risolvi_stato(o->>'res');
    if s.codice is null then
      out := out || case when s.metodo = 'incerto' then
        jsonb_build_object('campo', 'res', 'livello', 'errore', 'it', 'Paese non riconosciuto. Intendevi ' || initcap(s.descrizione) || '?', 'en', 'Country not recognised. Did you mean ' || initcap(s.descrizione) || '?', 'suggerito', initcap(s.descrizione))
      else jsonb_build_object('campo', 'res', 'livello', 'errore', 'it', 'Paese non riconosciuto: scegli dall''elenco.', 'en', 'Country not recognised: pick from the list.') end;
    elsif s.codice = '100000100' and nullif(btrim(o->>'resLoc'), '') is not null then
      select * into c from public.risolvi_comune(o->>'resLoc');
      if c.metodo = 'ambiguo' then
        out := out || jsonb_build_object('campo', 'resloc', 'livello', 'errore', 'it', 'Ci sono più comuni con questo nome: scegli quello giusto.', 'en', 'More than one town has this name: please choose.',
          'opzioni', (select jsonb_agg(initcap(x)) from regexp_split_to_table(c.descrizione, ', ') x));
      elsif c.codice is null then
        out := out || case when c.metodo = 'incerto' then
          jsonb_build_object('campo', 'resloc', 'livello', 'errore', 'it', 'Comune non trovato. Intendevi ' || initcap(c.descrizione) || '?', 'en', 'Town not found. Did you mean ' || initcap(c.descrizione) || '?', 'suggerito', initcap(c.descrizione))
        else jsonb_build_object('campo', 'resloc', 'livello', 'errore', 'it', 'Comune non trovato: scrivi il nome completo.', 'en', 'Town not found: please type the full name.') end;
      end if;
    end if;
  end if;

  if not titolare then return out; end if;

  -- Documento: tipo ammesso da Alloggiati Web
  if not exists (select 1 from public.tipi_documento d where d.codice = tdoc) then
    out := out || jsonb_build_object('campo', 'tdoc', 'livello', 'errore', 'it', 'Tipo di documento non valido.', 'en', 'Invalid document type.');
  end if;
  carta_ok := italiano or exists (select 1 from public.stati_carta_identita x where x.descrizione = ct.descrizione);
  if ct.codice is not null and not carta_ok and tdoc <> 'PASOR' then
    out := out || jsonb_build_object('campo', 'tdoc', 'livello', 'errore',
      'it', 'Per i cittadini di Paesi fuori dall''UE serve il passaporto.',
      'en', 'Guests from outside the EU must use their passport.', 'suggerito', 'PASOR');
  elsif tdoc = 'PATEN' and not italiano and ct.codice is not null then
    out := out || jsonb_build_object('campo', 'tdoc', 'livello', 'errore',
      'it', 'La patente straniera non vale come documento: usa carta d''identità o passaporto.',
      'en', 'A foreign driving licence is not accepted: please use your ID card or passport.', 'suggerito', 'PASOR');
  end if;

  -- Numero documento: solo lettere e numeri; per i documenti italiani controlliamo il formato
  ndoc := upper(coalesce(o->>'ndoc', ''));
  if btrim(ndoc) <> '' then
    if ndoc ~ '[^A-Z0-9 ]' then
      out := out || jsonb_build_object('campo', 'ndoc', 'livello', 'errore', 'it', 'Solo lettere e numeri, senza trattini o simboli.', 'en', 'Letters and numbers only, no dashes or symbols.',
        'suggerito', regexp_replace(ndoc, '[^A-Z0-9]', '', 'g'));
    else
      ndoc := replace(ndoc, ' ', '');
      if length(ndoc) < 5 or length(ndoc) > 20 then
        out := out || jsonb_build_object('campo', 'ndoc', 'livello', 'errore', 'it', 'Il numero sembra incompleto: ricopialo dal documento.', 'en', 'The number looks incomplete: please copy it from the document.');
      elsif italiano and (
           (tdoc = 'IDELE' and ndoc !~ '^[A-Z]{2}[0-9]{5}[A-Z]{2}$')
        or (tdoc = 'IDENT' and ndoc !~ '^[A-Z]{2}[0-9]{7}$')
        or (tdoc = 'PASOR' and ndoc !~ '^[A-Z]{2}[0-9]{7}$')
        or (tdoc = 'PATEN' and ndoc !~ '^[A-Z0-9]{10}$')) then
        out := out || jsonb_build_object('campo', 'ndoc', 'livello', 'avviso',
          'it', 'Controlla il numero: ' || case tdoc when 'IDELE' then 'sulla carta elettronica è in alto a destra, tipo CA12345AB.'
                                                 when 'IDENT' then 'sulla carta cartacea è tipo AA1234567.'
                                                 when 'PASOR' then 'sul passaporto è tipo YA1234567.'
                                                 else 'sulla patente è al punto 5, tipo U1AB23456C.' end,
          'en', 'Please double-check the number: ' || case tdoc when 'IDELE' then 'on the Italian electronic ID it looks like CA12345AB.'
                                                 when 'IDENT' then 'on the paper ID it looks like AA1234567.'
                                                 when 'PASOR' then 'on the passport it looks like YA1234567.'
                                                 else 'on the licence it is field 5, like U1AB23456C.' end);
      end if;
    end if;
  end if;

  -- Luogo di rilascio coerente con il documento
  if nullif(btrim(o->>'rilascio'), '') is not null then
    select * into ril_s from public.risolvi_stato(public.pulisci_ente(o->>'rilascio'));
    select * into ril_c from public.risolvi_comune(o->>'rilascio');
    if (italiano or ril_s.codice = '100000100') and not (ril_s.codice <> '100000100' and ril_s.metodo in ('alias', 'esatto')) is true then
      -- documento italiano: serve il Comune (carta) o la città della Questura/Motorizzazione
      if ril_c.codice is null then
        out := out || case
          when ril_c.metodo = 'ambiguo' then jsonb_build_object('campo', 'rilascio', 'livello', 'errore', 'it', 'Ci sono più comuni con questo nome: scegli quello giusto.', 'en', 'More than one town has this name: please choose.',
               'opzioni', (select jsonb_agg(initcap(x)) from regexp_split_to_table(ril_c.descrizione, ', ') x))
          when ril_c.metodo = 'incerto' then jsonb_build_object('campo', 'rilascio', 'livello', 'errore', 'it', 'Comune non trovato. Intendevi ' || initcap(ril_c.descrizione) || '?', 'en', 'Town not found. Did you mean ' || initcap(ril_c.descrizione) || '?', 'suggerito', initcap(ril_c.descrizione))
          else jsonb_build_object('campo', 'rilascio', 'livello', 'errore',
               'it', case when tdoc in ('IDENT', 'IDELE') then 'Scrivi il Comune che ha rilasciato la carta (es. Milano).' when tdoc = 'PASOR' then 'Scrivi la città della Questura che ha rilasciato il passaporto (es. Milano).' else 'Scrivi la città che ha rilasciato la patente (es. Milano).' end,
               'en', 'Please type the Italian town that issued the document (e.g. Milano).') end;
      end if;
    elsif ril_s.codice is null and ril_c.codice is null and ct.codice is null then
      out := out || jsonb_build_object('campo', 'rilascio', 'livello', 'errore', 'it', 'Scrivi il Paese che ha rilasciato il documento.', 'en', 'Please type the country that issued the document.');
    end if;
  end if;

  return out;
end $$;

-- Anche la schedina accetta gli apostrofi tipografici
create or replace function public.testo_schedina(t text, lunghezza int)
returns text language sql immutable set search_path = public, extensions as $f$
  select rpad(left(trim(regexp_replace(regexp_replace(upper(extensions.unaccent('extensions.unaccent'::regdictionary, translate(coalesce(t, ''), '’‘`´ʼ', ''''''''''''))), '[^A-Z'']', ' ', 'g'), '\s+', ' ', 'g')), lunghezza), lunghezza, ' ')
$f$;
grant execute on function public.testo_schedina(text, int) to service_role;

revoke all on function public.verifica_ospite(jsonb, boolean) from public, anon, authenticated;
grant execute on function public.verifica_ospite(jsonb, boolean) to service_role;

-- Rifiniture applicate dopo i test (vedi DB): fuzzystrmatch + suggerisci_comune (refusi tipo "Mialno" -> Milano,
-- con priorità alle lettere scambiate), messaggio dedicato se come luogo di rilascio si scrive "Italia".
