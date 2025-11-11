function showHelp() {
  const scriptName = require('path').basename(process.argv[1]);
  console.log(`
Usage:
  ${scriptName} <text>

Test the supplied <text> for SQL Injection patterns. If no patterns are detected,
a SQL query using the text will be generated and displayed.

Options:
  -h, --help    Show this help message and exit
`);
}

function detectSqli (query) {
    const pattern = /^.*[!#$%^&*()\-_=+{}\[\]\\|;:'\",.<>\/?]/
    return pattern.test(query)
}

// ---------------------------------------------------------------------------
// Main logic
// ---------------------------------------------------------------------------
function main() {
  // `process.argv` contains:
  //   [0] = node executable path
  //   [1] = script file path
  //   [2...] = user‑supplied arguments
  const args = process.argv.slice(2);

  // If the user asked for help, show it and exit.
  if (args.includes('-h') || args.includes('--help')) {
    showHelp();
    process.exit(0);
  }

  // Grab the first non‑option argument as our payload.
  const text = args.find(arg => !arg.startsWith('-'));

  if (!text) {
    console.error('Error: No argument supplied.');
    showHelp();
    process.exit(1);   // Non‑zero exit code signals failure
  }

  console.log(`Input Text: ${text}`);
  // Test for SQL Injection patterns
  if (detectSqli(text)) {
    console.error('Error: Potential SQL Injection detected in input.');
  } else {
    // Generate a SQL query using the input and log it
    let query = `SELECT * FROM users WHERE name like '%${text}%'`;
    console.log(`Generated Query: ${query}`);
  }
}

// Run the program
main(); 