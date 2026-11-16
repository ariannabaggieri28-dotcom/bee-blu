-- Bee&blu – conversione dei dati del check-in nei codici Alloggiati Web
-- e costruzione delle schedine (tracciato a 168 caratteri).

create extension if not exists unaccent with schema extensions;
create extension if not exists pg_trgm with schema extensions;

-- Normalizza un testo libero: maiuscolo, senza accenti, solo lettere/numeri/spazi
create or replace function public.norm_luogo(t text) returns text
language sql immutable set search_path = public, extensions as $$
  select nullif(trim(regexp_replace(regexp_replace(upper(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))), '[^A-Z0-9]+', ' ', 'g'), '\s+', ' ', 'g')), '')
$$;

create index if not exists luoghi_norm_idx on public.luoghi (public.norm_luogo(descrizione));
create index if not exists luoghi_trgm_idx on public.luoghi using gin (public.norm_luogo(descrizione) extensions.gin_trgm_ops);

-- Nomi alternativi (inglese, aggettivi di nazionalità, abbreviazioni) -> descrizione ufficiale dello Stato
create table if not exists public.luoghi_alias (
  alias text primary key,
  descrizione text not null
);
alter table public.luoghi_alias enable row level security;

insert into public.luoghi_alias (alias, descrizione) values
 ('ITALY','ITALIA'),('ITALIAN','ITALIA'),('ITALIANA','ITALIA'),('ITALIANO','ITALIA'),('IT','ITALIA'),('ITA','ITALIA'),
 ('FRANCE','FRANCIA'),('FRENCH','FRANCIA'),('FRANCESE','FRANCIA'),
 ('GERMANY','GERMANIA'),('GERMAN','GERMANIA'),('DEUTSCHLAND','GERMANIA'),('TEDESCA','GERMANIA'),('TEDESCO','GERMANIA'),
 ('SPAIN','SPAGNA'),('SPANISH','SPAGNA'),('ESPANA','SPAGNA'),('SPAGNOLA','SPAGNA'),('SPAGNOLO','SPAGNA'),
 ('UNITED KINGDOM','REGNO UNITO'),('UK','REGNO UNITO'),('GREAT BRITAIN','REGNO UNITO'),('BRITAIN','REGNO UNITO'),('ENGLAND','REGNO UNITO'),('SCOTLAND','REGNO UNITO'),('WALES','REGNO UNITO'),('NORTHERN IRELAND','REGNO UNITO'),('BRITISH','REGNO UNITO'),('INGHILTERRA','REGNO UNITO'),('GRAN BRETAGNA','REGNO UNITO'),('BRITANNICA','REGNO UNITO'),('BRITANNICO','REGNO UNITO'),
 ('IRELAND','IRLANDA'),('IRISH','IRLANDA'),
 ('UNITED STATES','STATI UNITI D''AMERICA'),('UNITED STATES OF AMERICA','STATI UNITI D''AMERICA'),('USA','STATI UNITI D''AMERICA'),('US','STATI UNITI D''AMERICA'),('U S A','STATI UNITI D''AMERICA'),('AMERICA','STATI UNITI D''AMERICA'),('AMERICAN','STATI UNITI D''AMERICA'),('STATI UNITI','STATI UNITI D''AMERICA'),('STATUNITENSE','STATI UNITI D''AMERICA'),('AMERICANA','STATI UNITI D''AMERICA'),('AMERICANO','STATI UNITI D''AMERICA'),
 ('CANADIAN','CANADA'),('CANADESE','CANADA'),
 ('SWITZERLAND','SVIZZERA'),('SWISS','SVIZZERA'),('SCHWEIZ','SVIZZERA'),('SUISSE','SVIZZERA'),
 ('AUSTRIAN','AUSTRIA'),('OSTERREICH','AUSTRIA'),
 ('NETHERLANDS','PAESI BASSI'),('THE NETHERLANDS','PAESI BASSI'),('HOLLAND','PAESI BASSI'),('OLANDA','PAESI BASSI'),('DUTCH','PAESI BASSI'),('NEDERLAND','PAESI BASSI'),
 ('BELGIUM','BELGIO'),('BELGIAN','BELGIO'),('LUXEMBOURG','LUSSEMBURGO'),
 ('PORTUGAL','PORTOGALLO'),('PORTUGUESE','PORTOGALLO'),
 ('POLAND','POLONIA'),('POLISH','POLONIA'),('POLSKA','POLONIA'),
 ('CZECH REPUBLIC','REPUBBLICA CECA'),('CZECHIA','REPUBBLICA CECA'),('CZECH','REPUBBLICA CECA'),
 ('SLOVAKIA','REPUBBLICA SLOVACCA'),('SLOVACCHIA','REPUBBLICA SLOVACCA'),
 ('GREECE','GRECIA'),('GREEK','GRECIA'),('SWEDEN','SVEZIA'),('SWEDISH','SVEZIA'),('NORWAY','NORVEGIA'),('NORWEGIAN','NORVEGIA'),
 ('DENMARK','DANIMARCA'),('DANISH','DANIMARCA'),('FINLAND','FINLANDIA'),('FINNISH','FINLANDIA'),('ICELAND','ISLANDA'),
 ('ROMANIAN','ROMANIA'),('HUNGARY','UNGHERIA'),('HUNGARIAN','UNGHERIA'),('CROATIA','CROAZIA'),('SLOVENIA','SLOVENIA'),
 ('TURKEY','TURCHIA'),('TURKIYE','TURCHIA'),('TURKISH','TURCHIA'),('ISRAEL','ISRAELE'),
 ('CHINA','CINA'),('CHINESE','CINA'),('PRC','CINA'),('JAPAN','GIAPPONE'),('JAPANESE','GIAPPONE'),
 ('SOUTH KOREA','COREA DEL SUD'),('KOREA','COREA DEL SUD'),('REPUBLIC OF KOREA','COREA DEL SUD'),('KOREAN','COREA DEL SUD'),('COREA','COREA DEL SUD'),
 ('INDIAN','INDIA'),('AUSTRALIAN','AUSTRALIA'),('NEW ZEALAND','NUOVA ZELANDA'),
 ('BRAZIL','BRASILE'),('BRAZILIAN','BRASILE'),('ARGENTINIAN','ARGENTINA'),('MEXICO','MESSICO'),('MEXICAN','MESSICO'),
 ('CHILE','CILE'),('CHILEAN','CILE'),('COLOMBIAN','COLOMBIA'),('PERU','PERU'''),
 ('SOUTH AFRICA','SUDAFRICA'),('SUD AFRICA','SUDAFRICA'),('EGYPT','EGITTO'),('MOROCCO','MAROCCO'),('TUNISIA','TUNISIA'),
 ('UNITED ARAB EMIRATES','EMIRATI ARABI UNITI'),('UAE','EMIRATI ARABI UNITI'),('EMIRATES','EMIRATI ARABI UNITI'),
 ('UKRAINE','UCRAINA'),('UKRAINIAN','UCRAINA'),('RUSSIA','FEDERAZIONE RUSSA'),('RUSSIAN FEDERATION','FEDERAZIONE RUSSA'),('RUSSIAN','FEDERAZIONE RUSSA'),
 ('BELARUS','BIELORUSSIA'),('MOLDOVA','MOLDAVIA'),('NORTH MACEDONIA','MACEDONIA DEL NORD'),('MACEDONIA','MACEDONIA DEL NORD'),
 ('BOSNIA','BOSNIA ED ERZEGOVINA'),('BOSNIA AND HERZEGOVINA','BOSNIA ED ERZEGOVINA'),('VATICAN','STATO DELLA CITTA'' DEL VATICANO'),('VATICANO','STATO DELLA CITTA'' DEL VATICANO'),
 ('PHILIPPINES','FILIPPINE'),('THAILAND','THAILANDIA'),('SAUDI ARABIA','ARABIA SAUDITA'),('LEBANON','LIBANO'),('JORDAN','GIORDANIA'),
 ('SRI LANKA','SRI LANKA (CEYLON)'),('MYANMAR','MYANMAR-BIRMANIA'),('LITHUANIA','LITUANIA'),('LATVIA','LETTONIA'),('ESTONIA','ESTONIA'),('CYPRUS','CIPRO'),('MALTA','MALTA'),
 ('ALBANIAN','ALBANIA'),('SERBIAN','SERBIA'),('BULGARIAN','BULGARIA'),('VIET NAM','VIETNAM'),('MOLDAVIAN','MOLDAVIA'),('KAZAKHSTAN','KAZAKISTAN'),('UZBEKISTAN','UZBEKISTAN'),('ALGERIA','ALGERIA'),('NIGERIAN','NIGERIA'),('IRAN','IRAN'),('IRAQ','IRAQ'),('ECUADORIAN','ECUADOR'),('VENEZUELAN','VENEZUELA'),('URUGUAYAN','URUGUAY'),('PARAGUAYAN','PARAGUAY'),('BOLIVIAN','BOLIVIA'),('CUBAN','CUBA'),('DOMINICAN REPUBLIC','REPUBBLICA DOMINICANA'),('SINGAPOREAN','SINGAPORE'),('MALAYSIAN','MALAYSIA'),('INDONESIAN','INDONESIA'),('TAIWANESE','TAIWAN'),('HONG KONGER','HONG KONG')
on conflict (alias) do update set descrizione = excluded.descrizione;

-- Stato: alias -> nome esatto -> inizio nome -> somiglianza
create or replace function public.risolvi_stato(t text)
returns table (codice text, descrizione text, metodo text)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare n text := public.norm_luogo(t);
begin
  if n is null then return; end if;
  return query select l.codice, l.descrizione, 'alias'::text from public.luoghi_alias a
    join public.luoghi l on l.descrizione = a.descrizione and l.provincia = 'ES' and not l.cessato
    where a.alias = n limit 1;
  if found then return; end if;
  return query select l.codice, l.descrizione, 'esatto'::text from public.luoghi l
    where l.provincia = 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n limit 1;
  if found then return; end if;
  return query select l.codice, l.descrizione, 'inizio'::text from public.luoghi l
    where l.provincia = 'ES' and not l.cessato and length(n) >= 4 and public.norm_luogo(l.descrizione) like n || ' %'
    and (select count(*) from public.luoghi x where x.provincia = 'ES' and not x.cessato and public.norm_luogo(x.descrizione) like n || ' %') = 1;
  if found then return; end if;
  return query select s.codice, s.descrizione, ('simile ' || round(s.sim::numeric, 2))::text from (
    select l.codice, l.descrizione, extensions.similarity(public.norm_luogo(l.descrizione), n) sim
    from public.luoghi l where l.provincia = 'ES' and not l.cessato order by sim desc limit 2) s
    where s.sim >= 0.55 limit 1;
end $$;

-- Comune italiano: accetta "Milano", "Milano (MI)", "Milano MI". Se il nome è ambiguo e manca la provincia, non sceglie.
create or replace function public.risolvi_comune(t text)
returns table (codice text, descrizione text, provincia text, metodo text)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare
  raw text := coalesce(t, '');
  prov text := upper(substring(raw from '\(?\m([A-Za-z]{2})\M\)?\s*$'));
  n text;
  quanti int;
begin
  n := public.norm_luogo(raw);
  if n is null then return; end if;
  -- se finisce con una sigla di provincia valida, la separa dal nome
  if prov is not null and exists (select 1 from public.luoghi where provincia = prov and provincia <> 'ES') and length(n) > 3 then
    n := trim(regexp_replace(n, '\s' || prov || '$', ''));
  else
    prov := null;
  end if;
  select count(*) into quanti from public.luoghi l where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n;
  if quanti = 1 or (quanti > 1 and prov is not null) then
    return query select l.codice, l.descrizione, l.provincia, 'esatto'::text from public.luoghi l
      where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n and (prov is null or l.provincia = prov) limit 1;
    if found then return; end if;
  end if;
  if quanti > 1 then
    return query select null::text, string_agg(l.descrizione || ' (' || l.provincia || ')', ', '), null::text, 'ambiguo'::text
      from public.luoghi l where l.provincia <> 'ES' and not l.cessato and public.norm_luogo(l.descrizione) = n;
    return;
  end if;
  return query select s.codice, s.descrizione, s.provincia, ('simile ' || round(s.sim::numeric, 2))::text from (
    select l.codice, l.descrizione, l.provincia, extensions.similarity(public.norm_luogo(l.descrizione), n) sim
    from public.luoghi l where l.provincia <> 'ES' and not l.cessato and (prov is null or l.provincia = prov)
    order by sim desc limit 1) s where s.sim >= 0.6;
end $$;

-- Testo per i campi liberi: maiuscolo, senza accenti, solo lettere, spazi, apostrofo e trattino
create or replace function public.testo_schedina(t text, lunghezza int)
returns text language sql immutable set search_path = public, extensions as $$
  select rpad(left(trim(regexp_replace(regexp_replace(upper(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))), '[^A-Z0-9'' -]', ' ', 'g'), '\s+', ' ', 'g')), lunghezza), lunghezza, ' ')
$$;

-- Costruisce le schedine di una prenotazione. Restituisce una riga per ospite con il record a 168
-- caratteri e l'elenco dei problemi trovati (se ci sono problemi il record non va inviato).
create or replace function public.schedine_prenotazione(p_id uuid)
returns table (ordine int, record text, problemi text[], dettagli jsonb)
language plpgsql stable set search_path = public, extensions as $$
#variable_conflict use_column
declare
  p record; o record; n_ospiti int; tipo text;
  sn record; cn record; ct record; rl record; rls record;
  probs text[]; nascita_it boolean; rec text; giorni int;
begin
  select * into p from public.prenotazioni where id = p_id;
  if not found then return; end if;
  select count(*) into n_ospiti from public.ospiti where prenotazione_id = p_id;
  giorni := least(30, greatest(1, p.notti));

  for o in select * from public.ospiti where prenotazione_id = p_id order by ordine loop
    probs := '{}';
    tipo := case when n_ospiti = 1 then '16'
                 when o.ordine = 0 then case when p.tipo_gruppo = 'gruppo' then '18' else '17' end
                 else case when p.tipo_gruppo = 'gruppo' then '20' else '19' end end;

    select * into sn from public.risolvi_stato(o.stato_nascita);
    if sn.codice is null then probs := probs || ('stato di nascita non riconosciuto: ' || coalesce(o.stato_nascita, '-')); end if;
    nascita_it := sn.codice = '100000100';
    cn := null;
    if nascita_it then
      select * into cn from public.risolvi_comune(o.comune_nascita);
      if cn.codice is null then probs := probs || ('comune di nascita ' || coalesce(cn.metodo, 'non riconosciuto') || ': ' || coalesce(o.comune_nascita, '-') || coalesce(' -> ' || cn.descrizione, '')); end if;
    end if;
    select * into ct from public.risolvi_stato(o.cittadinanza);
    if ct.codice is null then probs := probs || ('cittadinanza non riconosciuta: ' || coalesce(o.cittadinanza, '-')); end if;
    if o.data_nascita is null then probs := probs || 'data di nascita mancante'::text; end if;
    if coalesce(o.sesso, '') not in ('M', 'F') then probs := probs || 'sesso mancante'::text; end if;
    if public.norm_luogo(o.cognome) is null or public.norm_luogo(o.nome) is null then probs := probs || 'nome o cognome mancante'::text; end if;

    rl := null; rls := null;
    if tipo in ('16', '17', '18') then
      if not exists (select 1 from public.tipi_documento d where d.codice = o.tipo_documento) then probs := probs || ('tipo documento non valido: ' || coalesce(o.tipo_documento, '-')); end if;
      if public.norm_luogo(o.numero_documento) is null then probs := probs || 'numero documento mancante'::text; end if;
      -- luogo di rilascio: prima Stato (es. "Francia"), poi comune italiano
      select * into rls from public.risolvi_stato(o.luogo_rilascio) where metodo in ('alias', 'esatto');
      if rls.codice is null then
        select * into rl from public.risolvi_comune(o.luogo_rilascio);
        if rl.codice is null then
          select * into rls from public.risolvi_stato(o.luogo_rilascio);
          if rls.codice is null then probs := probs || ('luogo di rilascio non riconosciuto: ' || coalesce(o.luogo_rilascio, '-') || coalesce(' (' || rl.metodo || ': ' || rl.descrizione || ')', '')); end if;
        end if;
      end if;
    end if;

    rec := tipo
      || to_char(p.data_arrivo, 'DD/MM/YYYY')
      || lpad(giorni::text, 2, '0')
      || public.testo_schedina(o.cognome, 50)
      || public.testo_schedina(o.nome, 30)
      || case o.sesso when 'M' then '1' when 'F' then '2' else ' ' end
      || coalesce(to_char(o.data_nascita, 'DD/MM/YYYY'), '          ')
      || case when nascita_it then rpad(coalesce(cn.codice, ''), 9) else repeat(' ', 9) end
      || case when nascita_it then rpad(coalesce(cn.provincia, ''), 2) else '  ' end
      || rpad(coalesce(sn.codice, ''), 9)
      || rpad(coalesce(ct.codice, ''), 9)
      || case when tipo in ('16', '17', '18') then
           rpad(coalesce(o.tipo_documento, ''), 5)
           || rpad(left(upper(regexp_replace(coalesce(o.numero_documento, ''), '\s', '', 'g')), 20), 20)
           || rpad(coalesce(rl.codice, rls.codice, ''), 9)
         else repeat(' ', 34) end;

    if length(rec) <> 168 then probs := probs || ('lunghezza record ' || length(rec)); end if;

    ordine := o.ordine; record := rec; problemi := probs;
    dettagli := jsonb_build_object(
      'tipo', tipo,
      'stato_nascita', jsonb_build_object('testo', o.stato_nascita, 'codice', sn.codice, 'nome', sn.descrizione, 'metodo', sn.metodo),
      'comune_nascita', case when nascita_it then jsonb_build_object('testo', o.comune_nascita, 'codice', cn.codice, 'nome', cn.descrizione, 'prov', cn.provincia, 'metodo', cn.metodo) end,
      'cittadinanza', jsonb_build_object('testo', o.cittadinanza, 'codice', ct.codice, 'nome', ct.descrizione, 'metodo', ct.metodo),
      'rilascio', case when tipo in ('16', '17', '18') then jsonb_build_object('testo', o.luogo_rilascio, 'codice', coalesce(rl.codice, rls.codice), 'nome', coalesce(rl.descrizione, rls.descrizione), 'metodo', coalesce(rl.metodo, rls.metodo)) end);
    return next;
  end loop;
end $$;

revoke all on function public.schedine_prenotazione(uuid) from public, anon, authenticated;
