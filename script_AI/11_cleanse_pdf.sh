#!/usr/bin/env bash
# Directory where original files are stored (change if needed)
DIR_READ="pdf.in"
# Directory where cleaned files are stored (change if needed)
DIR_WRITE="pdf.out"

WATER_MARK="Wataru Taniguchi"

# Keep directory part of the command line for later use
COMMAND_DIR=$(dirname $0)

usage_exit(){
    echo "usage:" 1>&2
    echo "  $0" 1>&2
    echo
    echo "  $0 reads original PDF files" 1>&2 
    echo "  and produces cleaned PDF files" 1>&2
    exit 1
}

message(){
    echo "$(date +'%Y-%m-%d %T') " $@
}

check_command(){
    if ! command -v $1 2>&1 >/dev/null; then
        message "$1 could not be found"
        exit 1
    fi
}

touch_dir(){
    if [ ! -d $1 ]; then
        message "create_dir $1"
        mkdir $1
    fi
}

check_command qpdf
if [ ! -d "${DIR_READ}" ]; then
    message "$DIR_READ does not exist.  exiting..."
    exit 1
fi
rm -rf $DIR_WRITE > /dev/null 2>&1
touch_dir $DIR_WRITE

# Process all pdf files
for f in "${DIR_READ}"/*.pdf; do
    if [ ! -f $f ]; then
        continue
    fi
    PDF_BASE=$(basename $f)
    QDF_BASE=$(echo $PDF_BASE | sed s/\.pdf$/\.qdf/)
    # Convert to QDF format (a human-readable PDF format)
    message "converting $PDF_BASE to QDF format"
    qpdf --qdf "$f" "${DIR_WRITE}/${QDF_BASE}"
    message "removing metadata and watermarks from $QDF_BASE"
    cat "${DIR_WRITE}/${QDF_BASE}" | \
        # Remove metadata
        LC_ALL=C sed -E "/^[[:space:]]*\/(CreationDate|ModDate|Producer)[[:space:]]+.*$/d" | \
        # Remove water mark
        LC_ALL=C sed -E 's/^(.*'"$WATER_MARK"'.*)Tj[[:space:]]*$/()Tj/' \
        > "${DIR_WRITE}/temp-${QDF_BASE}"
    # Convert back to PDF format
    message "converting cleaned QDF back to PDF format: $PDF_BASE"
    fix-qdf < "${DIR_WRITE}/temp-${QDF_BASE}" > "${DIR_WRITE}/${PDF_BASE}"
    # Remove temporary files
    rm -f "${DIR_WRITE}/temp-${QDF_BASE}" "${DIR_WRITE}/${QDF_BASE}"
done
