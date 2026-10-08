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

async function readSheet(file: File): Promise<{ matrix: unknown[][] }> {
  const [buffer, XLSX] = await Promise.all([file.arrayBuffer(), import("xlsx")]);
  const workbook = XLSX.read(buffer, { type: "array", cellDates: false, raw: false });
  const sheet = workbook.Sheets[workbook.SheetNames[0]];
  if (!sheet) throw new Error("A planilha não tem uma aba com dados.");
  const range = XLSX.utils.decode_range(sheet["!ref"] ?? "A1");
  const matrix: unknown[][] = [];
  for (let row = range.s.r; row <= range.e.r; row += 1) {
    const values: unknown[] = [];
    for (let col = range.s.c; col <= range.e.c; col += 1) {
      const cell = sheet[XLSX.utils.encode_cell({ r: row, c: col })];
      values[col] = cell?.w ?? cell?.v ?? "";
    }
    matrix[row] = values;
  }
  return { matrix };
}

function cell(matrix: unknown[][], row: number, column: number): string {
  return String(matrix[row]?.[column] ?? "").trim();
}

function validUuid(value: string): string | null {
  const cleaned = value.trim().replace(/^\{|\}$/g, "").toLowerCase();
  return UUID.test(cleaned) ? cleaned : null;
}

async function sha256(file: File): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return [...new Uint8Array(digest)].map((part) => part.toString(16).padStart(2, "0")).join("");
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
  const { matrix } = await readSheet(file);
  if ((matrix[0]?.length ?? 0) < 40) throw new Error("A planilha Data Crazy precisa conter ao menos 40 colunas, incluindo AH e AN.");
  const rows = new Map<string, ReferralImportRow>();
  let invalidUuid = 0;
  let ignored = 0;
  let ambiguous = 0;
  let phoneUnavailable = 0;
  let invalidCpf = 0;
  let missingName = 0;
  let duplicateUuids = 0;

  // Fixed spreadsheet positions: B, D, K, AH, AI, AN (zero-based 1, 3, 10, 33, 34, 39).
  for (let index = 1; index < matrix.length; index += 1) {
    const uuid = validUuid(cell(matrix, index, 33));
    if (!uuid) {
      if (cell(matrix, index, 33)) invalidUuid += 1;
      continue;
    }
    const rawInfluencer = cell(matrix, index, 34);
    const normalizedInfluencer = normalizeInfluencer(rawInfluencer);
    if (normalizedInfluencer === "ignored") {
      ignored += 1;
      continue;
    }
    if (!normalizedInfluencer) ambiguous += 1;
    const phoneResult = cleanPhone(cell(matrix, index, 3));
    if (phoneResult.unavailable) phoneUnavailable += 1;
    const cpfValue = cell(matrix, index, 10);
    const cpf = cleanCpf(cpfValue);
    if (cpfValue && !cpf) invalidCpf += 1;
    const name = cell(matrix, index, 1);
    if (!name) missingName += 1;
    const candidate: ReferralImportRow = {
      uuid,
      name,
      region: cell(matrix, index, 39),
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
  }

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
    fileHash: await sha256(file),
    warnings,
    metrics: { total: rows.size, ambiguous, ignored, invalidUuid, phoneUnavailable, invalidCpf, duplicateUuids },
  };
}

export async function parsePerformance(file: File): Promise<ImportPreview<PerformanceImportRow>> {
  const { matrix } = await readSheet(file);
  if ((matrix[0]?.length ?? 0) < 18) throw new Error("A planilha Performance precisa conter ao menos 18 colunas, incluindo R.");
  const byUuid = new Map<string, PerformanceImportRow>();
  let invalidUuid = 0;
  let invalidRoutes = 0;
  let repeatedRows = 0;

  // Fixed spreadsheet positions: F UUID, G name, H region, R completed rides.
  for (let index = 1; index < matrix.length; index += 1) {
    const rawUuid = cell(matrix, index, 5);
    if (!rawUuid) continue;
    const uuid = validUuid(rawUuid);
    if (!uuid) {
      invalidUuid += 1;
      continue;
    }
    const rawRoutes = cell(matrix, index, 17).replace(/\s/g, "").replace(",", ".");
    const routes = Number(rawRoutes);
    if (!Number.isInteger(routes) || routes < 0) {
      invalidRoutes += 1;
      continue;
    }
    const wholeRoutes = routes;
    const previous = byUuid.get(uuid);
    if (previous) {
      previous.routes += wholeRoutes;
      if (!previous.name) previous.name = cell(matrix, index, 6);
      if (cell(matrix, index, 7)) previous.region = cell(matrix, index, 7);
      repeatedRows += 1;
    } else {
      byUuid.set(uuid, {
        uuid,
        name: cell(matrix, index, 6),
        region: cell(matrix, index, 7),
        routes: wholeRoutes,
      });
    }
  }
  const warnings: string[] = [];
  if (invalidUuid) warnings.push(`${invalidUuid} linha(s) foram ignoradas por não conterem UUID válido.`);
  if (invalidRoutes) warnings.push(`${invalidRoutes} linha(s) foram ignoradas por terem uma quantidade de corridas inválida.`);
  if (repeatedRows) warnings.push(`${repeatedRows} linha(s) do mesmo UUID foram somadas dentro desta importação.`);
  if (byUuid.size === 0) throw new Error("Nenhum UUID válido foi encontrado na coluna F.");
  return {
    rows: [...byUuid.values()],
    fileName: file.name,
    fileHash: await sha256(file),
    warnings,
    metrics: {
      total: byUuid.size,
      invalidUuid,
      invalidRoutes,
      sourceRows: matrix.length - 1,
      repeatedRows,
      totalRoutes: [...byUuid.values()].reduce((sum, item) => sum + item.routes, 0),
    },
  };
}

export function isInfluencerId(value: string): value is InfluencerId {
  return influencerIds.includes(value as InfluencerId);
}
