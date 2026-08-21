/**
 * Google Sheet license endpoint for The Gold Reaper v4.6.
 *
 * Bind this script to the spreadsheet that contains a "Licenses" tab and
 * deploy it as a Web app (execute as the owner, access: Anyone).
 *
 * When a new MT5 account contacts the endpoint, the script appends it with
 * Active=false and records its account/terminal telemetry. The EA stays
 * hidden until the owner changes Active to TRUE.
 */
const LICENSE_SHEET_NAME = 'Licenses';
const LICENSE_HEADERS = [
  'Name',
  'Account',
  'Active',
  'ExpiryUTC',
  'AllowedServer',
  'Product',
  'AccountName',
  'Broker',
  'DetectedServer',
  'Currency',
  'Balance',
  'Equity',
  'Leverage',
  'TradeMode',
  'Symbol',
  'Terminal',
  'TerminalBuild',
  'FirstSeenUTC',
  'LastSeenUTC',
  'LastResult',
];

function doGet(e) {
  const params = (e && e.parameter) || {};
  const account = clean_(params.account);
  const server = clean_(params.server);
  const product = clean_(params.product);

  try {
    const expectedKey = PropertiesService.getScriptProperties()
      .getProperty('LICENSE_API_KEY') || '';
    if (expectedKey && clean_(params.key) !== expectedKey) {
      return text_('DENIED|invalid_key');
    }
    if (!/^\d+$/.test(account)) {
      return text_('DENIED|invalid_account');
    }

    const lock = LockService.getScriptLock();
    if (!lock.tryLock(5000)) {
      return text_('ERROR|busy');
    }

    try {
      const spreadsheet = SpreadsheetApp.getActiveSpreadsheet();
      const sheet = spreadsheet.getSheetByName(LICENSE_SHEET_NAME);
      if (!sheet) {
        return text_('ERROR|missing_licenses_sheet');
      }

      ensureSchema_(sheet);
      const rows = sheet.getDataRange().getValues();
      const columns = mapColumns_(rows[0]);
      if (columns.account < 0 || columns.active < 0) {
        return text_('ERROR|missing_account_or_active_column');
      }

      let firstAccountRow = -1;
      let matchingRow = -1;
      for (let i = 1; i < rows.length; i += 1) {
        const row = rows[i];
        if (clean_(row[columns.account]) !== account) continue;
        if (firstAccountRow < 0) firstAccountRow = i;
        if (!scopeMatches_(cell_(row, columns.allowedServer), server)) continue;
        if (!scopeMatches_(cell_(row, columns.product), product)) continue;
        matchingRow = i;
        break;
      }

      if (firstAccountRow < 0) {
        appendPendingAccount_(sheet, columns, params);
        return text_('DENIED|pending_approval');
      }

      if (matchingRow < 0) {
        writeTelemetry_(sheet, firstAccountRow + 1, rows[firstAccountRow],
          columns, params, 'DENIED: SCOPE');
        return text_('DENIED|server_or_product_not_allowed');
      }

      const row = rows[matchingRow];
      if (!isActive_(cell_(row, columns.active))) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'DENIED: INACTIVE');
        return text_('DENIED|license_inactive');
      }

      const expiry = expiryUnix_(cell_(row, columns.expiry));
      if (expiry === null) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'ERROR: EXPIRY');
        return text_('ERROR|invalid_expiry');
      }
      if (expiry > 0 && Math.floor(Date.now() / 1000) >= expiry) {
        writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
          'DENIED: EXPIRED');
        return text_('DENIED|license_expired');
      }

      writeTelemetry_(sheet, matchingRow + 1, row, columns, params,
        'APPROVED');
      const displayName = safeField_(
        cell_(row, columns.name) || clean_(params.account_name));
      return text_('OK|' + expiry + '|' + displayName);
    } finally {
      lock.releaseLock();
    }
  } catch (error) {
    console.error(error);
    return text_('ERROR|server_error');
  }
}

function ensureSchema_(sheet) {
  if (sheet.getLastRow() === 0 || sheet.getLastColumn() === 0) {
    sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
      .setValues([LICENSE_HEADERS]);
    return;
  }

  const lastColumn = sheet.getLastColumn();
  const headers = sheet.getRange(1, 1, 1, lastColumn).getValues()[0];
  const normalized = headers.map(normalizeHeader_);
  const missing = [];
  LICENSE_HEADERS.slice(6).forEach(function (header) {
    if (!normalized.includes(normalizeHeader_(header))) missing.push(header);
  });
  if (missing.length > 0) {
    sheet.getRange(1, lastColumn + 1, 1, missing.length)
      .setValues([missing]);
  }
}

function appendPendingAccount_(sheet, columns, params) {
  const now = new Date();
  const row = new Array(sheet.getLastColumn()).fill('');
  setCell_(row, columns.account, clean_(params.account));
  setCell_(row, columns.active, false);
  setCell_(row, columns.expiry, '');
  setCell_(row, columns.name, clean_(params.account_name));
  setCell_(row, columns.allowedServer, clean_(params.server) || '*');
  setCell_(row, columns.product, clean_(params.product));
  setTelemetryValues_(row, columns, params, now, now, 'WAITING APPROVAL');
  sheet.appendRow(row);
}

function writeTelemetry_(sheet, rowNumber, currentRow, columns, params, status) {
  const now = new Date();
  const row = currentRow.slice();
  while (row.length < sheet.getLastColumn()) row.push('');
  const firstSeen = cell_(row, columns.firstSeen) || now;
  setTelemetryValues_(row, columns, params, firstSeen, now, status);

  const firstColumn = columns.accountName;
  const lastColumn = columns.lastResult;
  if (firstColumn < 0 || lastColumn < firstColumn) return;
  sheet.getRange(rowNumber, firstColumn + 1, 1,
    lastColumn - firstColumn + 1)
    .setValues([row.slice(firstColumn, lastColumn + 1)]);
}

function setTelemetryValues_(row, columns, params, firstSeen, lastSeen, status) {
  setCell_(row, columns.accountName, clean_(params.account_name));
  setCell_(row, columns.broker, clean_(params.broker));
  setCell_(row, columns.detectedServer, clean_(params.server));
  setCell_(row, columns.currency, clean_(params.currency));
  setCell_(row, columns.balance, numberOrBlank_(params.balance));
  setCell_(row, columns.equity, numberOrBlank_(params.equity));
  setCell_(row, columns.leverage, integerOrBlank_(params.leverage));
  setCell_(row, columns.tradeMode, clean_(params.trade_mode));
  setCell_(row, columns.symbol, clean_(params.symbol));
  setCell_(row, columns.terminal, clean_(params.terminal));
  setCell_(row, columns.terminalBuild, integerOrBlank_(params.build));
  setCell_(row, columns.firstSeen, firstSeen);
  setCell_(row, columns.lastSeen, lastSeen);
  setCell_(row, columns.lastResult, status);
}

function mapColumns_(headerRow) {
  const result = {
    account: -1,
    active: -1,
    expiry: -1,
    name: -1,
    allowedServer: -1,
    product: -1,
    accountName: -1,
    broker: -1,
    detectedServer: -1,
    currency: -1,
    balance: -1,
    equity: -1,
    leverage: -1,
    tradeMode: -1,
    symbol: -1,
    terminal: -1,
    terminalBuild: -1,
    firstSeen: -1,
    lastSeen: -1,
    lastResult: -1,
  };

  headerRow.forEach(function (value, index) {
    const header = normalizeHeader_(value);
    if (['account', 'accountlogin', 'login', 'mt5account'].includes(header)) {
      result.account = index;
    } else if (['active', 'status', 'enabled'].includes(header)) {
      result.active = index;
    } else if (['expiryutc', 'expiresutc', 'expiry', 'expiration', 'expire'].includes(header)) {
      result.expiry = index;
    } else if (['name', 'customername', 'customname', 'customer', 'client'].includes(header)) {
      result.name = index;
    } else if (['allowedserver', 'server', 'serverscope'].includes(header)) {
      result.allowedServer = index;
    } else if (['product', 'ea'].includes(header)) {
      result.product = index;
    } else if (header === 'accountname') {
      result.accountName = index;
    } else if (['broker', 'company'].includes(header)) {
      result.broker = index;
    } else if (['detectedserver', 'actualserver'].includes(header)) {
      result.detectedServer = index;
    } else if (header === 'currency') {
      result.currency = index;
    } else if (header === 'balance') {
      result.balance = index;
    } else if (header === 'equity') {
      result.equity = index;
    } else if (header === 'leverage') {
      result.leverage = index;
    } else if (header === 'trademode') {
      result.tradeMode = index;
    } else if (header === 'symbol') {
      result.symbol = index;
    } else if (header === 'terminal') {
      result.terminal = index;
    } else if (['terminalbuild', 'build'].includes(header)) {
      result.terminalBuild = index;
    } else if (['firstseenutc', 'firstseen'].includes(header)) {
      result.firstSeen = index;
    } else if (['lastseenutc', 'lastseen'].includes(header)) {
      result.lastSeen = index;
    } else if (['lastresult', 'result'].includes(header)) {
      result.lastResult = index;
    }
  });
  return result;
}

/**
 * Optional one-time helper. Run this manually after pasting the script if the
 * spreadsheet was not created from the supplied template.
 */
function setupLicenseSheet() {
  const sheet = SpreadsheetApp.getActiveSpreadsheet()
    .getSheetByName(LICENSE_SHEET_NAME);
  if (!sheet) throw new Error('Missing Licenses sheet');

  sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
    .setValues([LICENSE_HEADERS]);
  sheet.setFrozenRows(1);
  sheet.setFrozenColumns(3);
  try {
    sheet.getRange('C2:C1000').insertCheckboxes();
  } catch (error) {
    // The supplied native table already renders its BOOLEAN column as checks.
    console.log('Active checkbox setup skipped: ' + error.message);
  }
  sheet.getRange('D2:D1000').setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange('K2:L1000').setNumberFormat('#,##0.00');
  sheet.getRange('R2:S1000').setNumberFormat('yyyy-mm-dd hh:mm:ss');
  sheet.getRange(1, 1, 1, LICENSE_HEADERS.length)
    .setBackground('#e8eaed')
    .setFontWeight('bold')
    .setHorizontalAlignment('center')
    .setVerticalAlignment('middle')
    .setWrap(true);

  const widths = [
    170, 105, 75, 150, 175, 170, 190, 190, 175, 85,
    105, 105, 85, 95, 105, 130, 105, 155, 155, 150,
  ];
  widths.forEach(function (width, index) {
    sheet.setColumnWidth(index + 1, width);
  });

  const dataRange = sheet.getRange('A2:T1000');
  const rules = [
    SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=$C2=TRUE')
      .setBackground('#e6f4ea')
      .setRanges([dataRange])
      .build(),
    SpreadsheetApp.newConditionalFormatRule()
      .whenFormulaSatisfied('=$C2=FALSE')
      .setBackground('#fce8e6')
      .setRanges([dataRange])
      .build(),
  ];
  sheet.setConditionalFormatRules(rules);
}

function normalizeHeader_(value) {
  return clean_(value).toLowerCase().replace(/[\s_-]/g, '');
}

function clean_(value) {
  return value === null || value === undefined ? '' : String(value).trim();
}

function cell_(row, index) {
  return index >= 0 && index < row.length ? row[index] : '';
}

function setCell_(row, index, value) {
  if (index >= 0) row[index] = value;
}

function scopeMatches_(configured, actual) {
  const expected = clean_(configured).toUpperCase();
  return !expected || expected === '*' || expected === clean_(actual).toUpperCase();
}

function isActive_(value) {
  return value === true || ['ACTIVE', 'ENABLED', 'TRUE', 'YES', '1', 'OK']
    .includes(clean_(value).toUpperCase());
}

function expiryUnix_(value) {
  if (value === '' || value === null || value === undefined) return 0;
  if (value instanceof Date) {
    const milliseconds = value.getTime();
    return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
  }

  const text = clean_(value);
  if (!text || ['0', 'NEVER', 'PERMANENT', 'UNLIMITED'].includes(text.toUpperCase())) {
    return 0;
  }
  if (/^\d+$/.test(text)) {
    const unix = Number(text);
    return Number.isSafeInteger(unix) && unix > 1000000000 ? unix : null;
  }

  const milliseconds = Date.parse(text);
  return Number.isNaN(milliseconds) ? null : Math.floor(milliseconds / 1000);
}

function numberOrBlank_(value) {
  const number = Number(value);
  return clean_(value) && Number.isFinite(number) ? number : '';
}

function integerOrBlank_(value) {
  const number = Number(value);
  return clean_(value) && Number.isFinite(number) ? Math.trunc(number) : '';
}

function safeField_(value) {
  return clean_(value).replace(/[|\r\n]/g, ' ');
}

function text_(body) {
  return ContentService.createTextOutput(body)
    .setMimeType(ContentService.MimeType.TEXT);
}
