BEGIN;
-- Feedback: cuaca jangan diisi per item SMS (berulang-ulang) -- taruh di atas sebagai "main",
-- satu per WO per tanggal per shift. Kondisi cuaca + jam efektif tetap manual, suhu diisi
-- otomatis di browser (Open-Meteo, dari Lokasi Proyek WO) lalu ikut disimpan di sini.
-- sms_item_weather lama TIDAK di-drop (arsip); datanya di-backfill ke tabel baru ini.

CREATE TABLE operational.wo_weather (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
 wo_id uuid NOT NULL REFERENCES operational.work_orders(id),
 report_date date NOT NULL,
 shift text NOT NULL CHECK(shift IN ('PAGI','SIANG','LEMBUR')),
 weather text CHECK(weather IS NULL OR weather IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT')),
 temperature_c numeric,
 effective_hours numeric CHECK(effective_hours IS NULL OR effective_hours>=0),
 recorded_by bigint NOT NULL,
 updated_at timestamptz NOT NULL DEFAULT now(),
 UNIQUE(wo_id,report_date,shift)
);
ALTER TABLE operational.wo_weather ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON operational.wo_weather FROM PUBLIC,anon,authenticated;

-- Backfill: kalau satu WO/tanggal/shift punya beberapa item dengan cuaca beda, diambil salah
-- satunya (sms_item_weather gak punya timestamp buat nentuin mana yang terakhir).
INSERT INTO operational.wo_weather(wo_id,report_date,shift,weather,temperature_c,effective_hours,recorded_by)
SELECT DISTINCT ON (si.wo_id,w.report_date,w.shift) si.wo_id,w.report_date,w.shift,w.weather,w.temperature_c,w.effective_hours,w.recorded_by
FROM operational.sms_item_weather w
JOIN operational.sms_items si ON si.id=w.sms_item_id
ORDER BY si.wo_id,w.report_date,w.shift,w.id;

CREATE OR REPLACE FUNCTION public.op_weather(p_token text, p_action text, p_data jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
DECLARE actor bigint; woid uuid; rdate date; wid uuid; max_hours numeric;
BEGIN
 actor:=operational.check_session(p_token,ARRAY['operational wo']);
 woid:=nullif(p_data->>'woId','')::uuid;
 IF woid IS NULL OR NOT EXISTS(SELECT 1 FROM operational.work_orders WHERE id=woid) THEN RAISE EXCEPTION 'WO tidak ditemukan'; END IF;
 IF nullif(p_data->>'reportDate','') IS NULL THEN RAISE EXCEPTION 'Tanggal wajib diisi'; END IF;
 rdate:=(p_data->>'reportDate')::date;
 IF p_action='list' THEN
  RETURN coalesce((SELECT jsonb_agg(jsonb_build_object('shift',w.shift,'weather',w.weather,'temperatureC',w.temperature_c,'effectiveHours',w.effective_hours)
   ORDER BY array_position(ARRAY['PAGI','SIANG','LEMBUR'],w.shift))
   FROM operational.wo_weather w WHERE w.wo_id=woid AND w.report_date=rdate),'[]');
 ELSIF p_action='save' THEN
  IF p_data->>'shift' NOT IN ('PAGI','SIANG','LEMBUR') THEN RAISE EXCEPTION 'Shift tidak valid'; END IF;
  IF nullif(p_data->>'weather','') IS NOT NULL AND p_data->>'weather' NOT IN ('CERAH','BERAWAN','HUJAN_RINGAN','HUJAN_LEBAT') THEN RAISE EXCEPTION 'Kondisi cuaca tidak valid'; END IF;
  max_hours:=CASE WHEN p_data->>'shift'='LEMBUR' THEN 3.5 ELSE 4 END;
  IF nullif(p_data->>'effectiveHours','') IS NOT NULL AND (p_data->>'effectiveHours')::numeric>max_hours THEN
   RAISE EXCEPTION 'Jam efektif melebihi durasi shift (maks % jam)',max_hours;
  END IF;
  -- Semua field kosong = hapus baris shift itu (biar cuaca yang salah isi bisa dikosongkan lagi)
  IF nullif(p_data->>'weather','') IS NULL AND nullif(p_data->>'effectiveHours','') IS NULL AND nullif(p_data->>'temperatureC','') IS NULL THEN
   DELETE FROM operational.wo_weather WHERE wo_id=woid AND report_date=rdate AND shift=p_data->>'shift';
   RETURN jsonb_build_object('deleted',true);
  END IF;
  INSERT INTO operational.wo_weather(wo_id,report_date,shift,weather,temperature_c,effective_hours,recorded_by)
  VALUES(woid,rdate,p_data->>'shift',nullif(p_data->>'weather',''),nullif(p_data->>'temperatureC','')::numeric,nullif(p_data->>'effectiveHours','')::numeric,actor)
  ON CONFLICT (wo_id,report_date,shift) DO UPDATE SET weather=excluded.weather,temperature_c=excluded.temperature_c,effective_hours=excluded.effective_hours,recorded_by=excluded.recorded_by,updated_at=now()
  RETURNING id INTO wid;
  RETURN jsonb_build_object('id',wid);
 END IF;
 RAISE EXCEPTION 'Aksi tidak dikenal';
END;
$function$;
REVOKE ALL ON FUNCTION public.op_weather(text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.op_weather(text,text,jsonb) TO anon,authenticated;
COMMIT;
