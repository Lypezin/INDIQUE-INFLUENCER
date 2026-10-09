export type InfluencerId =
  | "jaiminho"
  | "jhowjhow"
  | "felipe"
  | "00-brocador"
  | "sassa"
  | "vini"
  | "gui"
  | "biel"
  | "thais";

export type ReferralImportRow = {
  uuid: string;
  name: string;
  region: string;
  phone: string | null;
  cpf: string | null;
  influencerId: InfluencerId | null;
  rawInfluencer: string;
  phoneUnavailable: boolean;
};

export type PerformanceImportRow = {
  uuid: string;
  name: string;
  region: string;
  routes: number;
};

export type ImportPreview<T> = {
  rows: T[];
  fileName: string;
  fileHash: string;
  warnings: string[];
  metrics: Record<string, number>;
};

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_IMPORT_FILE_BYTES = 25 * 1024 * 1024;
const MAX_IMPORT_SOURCE_ROWS = 100_000;
const influencerIds: InfluencerId[] = [
  "jaiminho", "jhowjhow", "felipe", "00-brocador", "sassa", "vini", "gui", "biel", "thais",
];

function repairMojibake(input: string): string {
  if (!/[ÃÂ]/.test(input)) return input;
  try {
    const bytes = Uint8Array.from([...input], (character) => character.charCodeAt(0) & 0xff);
    const repaired = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    return repaired.includes("�") ? input : repaired;
  } catch {
    return input;
  }
}

function normalizeText(input: unknown): string {
  return repairMojibake(String(input ?? ""))
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("pt-BR")
    .replace(/[^a-z0-9]+/g, " ")
    .trim();
}

export function normalizeInfluencer(value: unknown): InfluencerId | "ignored" | null {
  const normalized = normalizeText(value);
  if (!normalized) return null;
  if (/\b(caio|marreta)\b/.test(normalized)) return "ignored";

  // Match the name anywhere so "Indicação JhowJhow" and mojibake prefixes still work.
  const compact = normalized.replace(/\s/g, "");
  if (compact.includes("jaiminho")) return "jaiminho";
  if (compact.includes("jhowjhow") || compact.includes("jhowhow") || compact.includes("jhow")) return "jhowjhow";
  if (compact.includes("00broc") || compact.includes("0broc") || compact.includes("brocador")) return "00-brocador";
  if (compact.includes("felipe")) return "felipe";
  if (compact.includes("sassa") || compact.includes("sasa")) return "sassa";
  if (compact.includes("guilherme") || normalized.split(" ").includes("gui")) return "gui";
  if (compact.includes("vini")) return "vini";
  if (compact.includes("thais")) return "thais";
  if (normalized.split(" ").includes("biel")) return "biel";
  if (/\b(instagram|whatsapp|google|youtube|panfletagem)\b/.test(normalized) || normalized.includes("ponto de apoio")) return "ignored";
  return null;
}

type SelectedRowConsumer = (values: string[]) => void;

async function forEachSpreadsheetRow(
  file: File,
  minimumColumns: number,
  selectedColumns: readonly number[],
  consume: SelectedRowConsumer,
): Promise<{ fileHash: string; sourceRows: number }> {
  if (file.size > MAX_IMPORT_FILE_BYTES) {
    throw new Error("O arquivo excede o limite local de 25 MB para leitura no navegador.");
  }

  const [buffer, XLSX] = await Promise.all([file.arrayBuffer(), import("xlsx")]);
  if (buffer.byteLength > MAX_IMPORT_FILE_BYTES) {
    throw new Error("O arquivo excede o limite local de 25 MB para leitura no navegador.");
  }
  const workbook = XLSX.read(buffer, {
    type: "array",
    cellDates: false,
    cellFormula: false,
    cellHTML: false,
    raw: false,
    // Keep one sentinel row so an oversized file can be rejected instead of silently truncated.
    sheetRows: MAX_IMPORT_SOURCE_ROWS + 2,
  });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  if (!sheet) throw new Error("A planilha não tem uma aba com dados.");

  const rangeRef = sheet["!fullref"] ?? sheet["!ref"];
  if (!rangeRef) throw new Error("A planilha não tem uma aba com dados.");
  const range = XLSX.utils.decode_range(rangeRef);
  if (range.s.r !== 0) throw new Error("O cabeçalho da planilha precisa estar na primeira linha.");
  if (range.e.c + 1 < minimumColumns) {
    throw new Error(`A planilha precisa conter ao menos ${minimumColumns} colunas.`);
  }
  const sourceRows = range.e.r;
  if (sourceRows > MAX_IMPORT_SOURCE_ROWS) {
    throw new Error(`A planilha excede o limite de ${MAX_IMPORT_SOURCE_ROWS.toLocaleString("pt-BR")} linhas de dados.`);
  }

  for (let row = 1; row <= sourceRows; row += 1) {
    const values = selectedColumns.map((column) => {
      const address = XLSX.utils.encode_cell({ r: row, c: column });
      const value = (sheet as Record<string, unknown>)[address];
      if (typeof value !== "object" || value === null) return "";
      const cell = value as { w?: unknown; v?: unknown };
      return String(cell.w ?? cell.v ?? "").trim();
    });
    consume(values);
    // Let the browser paint between batches when projecting large worksheets.
    if (row % 2_000 === 0) await new Promise<void>((resolve) => setTimeout(resolve, 0));
  }

  const digest = await crypto.subtle.digest("SHA-256", buffer);
  const fileHash = [...new Uint8Array(digest)].map((part) => part.toString(16).padStart(2, "0")).join("");
  return { fileHash, sourceRows };
}

function validUuid(value: string): string | null {
  const cleaned = value.trim().replace(/^\{|\}$/g, "").toLowerCase();
  return UUID.test(cleaned) ? cleaned : null;
}

function cleanPhone(value: string): { phone: string | null; unavailable: boolean } {
  const phone = value.trim();
  if (!phone) return { phone: null, unavailable: false };
  if (/[eE][+-]?\d+/.test(phone) || /^\d+(?:\.\d+)?[eE]\+?\d+$/i.test(phone)) {
    return { phone: null, unavailable: true };
  }
  const digits = phone.replace(/\D/g, "");
  if (digits.length < 10 || digits.length > 13) return { phone: null, unavailable: false };
  return { phone: digits, unavailable: false };
}

function cleanCpf(value: string): string | null {
  const digits = value.replace(/\D/g, "");
  if (digits.length !== 11 || /^([0-9])\1{10}$/.test(digits)) return null;
  const checkDigit = (slice: string, initialWeight: number) => {
    const sum = [...slice].reduce((total, digit, index) => total + Number(digit) * (initialWeight - index), 0);
    const remainder = (sum * 10) % 11;
    return remainder === 10 ? 0 : remainder;
  };
  return Number(digits[9]) === checkDigit(digits.slice(0, 9), 10)
    && Number(digits[10]) === checkDigit(digits.slice(0, 10), 11)
    ? digits
    : null;
}

export async function parseDataCrazy(file: File): Promise<ImportPreview<ReferralImportRow>> {
  const rows = new Map<string, ReferralImportRow>();
  let invalidUuid = 0;
  let ignored = 0;
  let ambiguous = 0;
  let phoneUnavailable = 0;
  let invalidCpf = 0;
  let missingName = 0;
  let duplicateUuids = 0;

  // Fixed spreadsheet positions: B, D, K, AH, AI, AN (zero-based 1, 3, 10, 33, 34, 39).
  const { fileHash } = await forEachSpreadsheetRow(file, 40, [1, 3, 10, 33, 34, 39], (values) => {
    const [nameValue, phoneValue, cpfValue, rawUuid, rawInfluencer, region] = values;
    const uuid = validUuid(rawUuid);
    if (!uuid) {
      if (rawUuid) invalidUuid += 1;
      return;
    }
    const normalizedInfluencer = normalizeInfluencer(rawInfluencer);
    if (normalizedInfluencer === "ignored") {
      ignored += 1;
      return;
    }
    if (!normalizedInfluencer) ambiguous += 1;
    const phoneResult = cleanPhone(phoneValue);
    if (phoneResult.unavailable) phoneUnavailable += 1;
    const cpf = cleanCpf(cpfValue);
    if (cpfValue && !cpf) invalidCpf += 1;
    const name = nameValue;
    if (!name) missingName += 1;
    const candidate: ReferralImportRow = {
      uuid,
      name,
      region,
      phone: phoneResult.phone,
      cpf,
      influencerId: normalizedInfluencer,
      rawInfluencer,
      phoneUnavailable: phoneResult.unavailable,
    };
    const previous = rows.get(uuid);
    if (previous) {
      duplicateUuids += 1;
      if (previous.influencerId !== candidate.influencerId) {
        candidate.influencerId = null;
        candidate.rawInfluencer = `${previous.rawInfluencer} / ${rawInfluencer}`.trim();
        ambiguous += 1;
      }
    }
    rows.set(uuid, candidate);
  });

  const warnings: string[] = [];
  if (phoneUnavailable) warnings.push(`${phoneUnavailable} telefone(s) vieram em notação científica e ficarão indisponíveis.`);
  if (invalidCpf) warnings.push(`${invalidCpf} CPF(s) não passaram na validação e serão omitidos.`);
  if (ambiguous) warnings.push(`${ambiguous} UUID(s) têm uma atribuição que precisa de revisão administrativa.`);
  if (invalidUuid) warnings.push(`${invalidUuid} linha(s) foram ignoradas por não conterem UUID válido.`);
  if (duplicateUuids) warnings.push(`${duplicateUuids} UUID(s) repetidos foram consolidados; conflitos de influenciador ficaram para revisão.`);
  if (missingName) warnings.push(`${missingName} entregador(es) estão sem nome no arquivo.`);
  if (rows.size === 0) throw new Error("Nenhum UUID válido foi encontrado na coluna AH.");

  return {
    rows: [...rows.values()],
    fileName: file.name,
    fileHash,
    warnings,
    metrics: { total: rows.size, ambiguous, ignored, invalidUuid, phoneUnavailable, invalidCpf, duplicateUuids },
  };
}

export async function parsePerformance(file: File): Promise<ImportPreview<PerformanceImportRow>> {
  const byUuid = new Map<string, PerformanceImportRow>();
  let invalidUuid = 0;
  let invalidRoutes = 0;
  let repeatedRows = 0;

  // Fixed spreadsheet positions: F UUID, G name, H region, R completed rides.
  const { fileHash, sourceRows } = await forEachSpreadsheetRow(file, 18, [5, 6, 7, 17], (values) => {
    const [rawUuid, name, region, rawRouteValue] = values;
    if (!rawUuid) return;
    const uuid = validUuid(rawUuid);
    if (!uuid) {
      invalidUuid += 1;
      return;
    }
    const rawRoutes = rawRouteValue.replace(/\s/g, "").replace(",", ".");
    const routes = Number(rawRoutes);
    if (!Number.isInteger(routes) || routes < 0) {
      invalidRoutes += 1;
      return;
    }
    const wholeRoutes = routes;
    const previous = byUuid.get(uuid);
    if (previous) {
      previous.routes += wholeRoutes;
      if (!previous.name) previous.name = name;
      if (region) previous.region = region;
      repeatedRows += 1;
    } else {
      byUuid.set(uuid, {
        uuid,
        name,
        region,
        routes: wholeRoutes,
      });
    }
  });
  const warnings: string[] = [];
  if (invalidUuid) warnings.push(`${invalidUuid} linha(s) foram ignoradas por não conterem UUID válido.`);
  if (invalidRoutes) warnings.push(`${invalidRoutes} linha(s) foram ignoradas por terem uma quantidade de corridas inválida.`);
  if (repeatedRows) warnings.push(`${repeatedRows} linha(s) do mesmo UUID foram somadas dentro desta importação.`);
  if (byUuid.size === 0) throw new Error("Nenhum UUID válido foi encontrado na coluna F.");
  return {
    rows: [...byUuid.values()],
    fileName: file.name,
    fileHash,
    warnings,
    metrics: {
      total: byUuid.size,
      invalidUuid,
      invalidRoutes,
      sourceRows,
      repeatedRows,
      totalRoutes: [...byUuid.values()].reduce((sum, item) => sum + item.routes, 0),
    },
  };
}

export function isInfluencerId(value: string): value is InfluencerId {
  return influencerIds.includes(value as InfluencerId);
}
