#
# Copyright 2016, Data61, CSIRO
#
# This software may be distributed and modified according to the terms of
# the BSD 2-Clause license. Note that NO WARRANTY is provided.
# See "LICENSE_BSD2.txt" for details.
#
# @TAG(DATA61_BSD)
#

# note this makefile will not work entirely correctly if invoked in the local
# directory; make really needs to be invoked in the parent directory, or
# further up still

STP_PFX := $(realpath $(dir $(lastword $(MAKEFILE_LIST))))

ISABELLE_HOME ?= $(STP_PFX)/../../../isabelle

ifndef STP_INCLUDED
STP_INCLUDED=true

ARM_DIR=$(STP_PFX)/ARM
ARM_HYP_DIR=$(STP_PFX)/ARM_HYP
X64_DIR=$(STP_PFX)/X64
ARCH_DIRS=$(ARM_DIR) $(ARM_HYP_DIR) $(X64_DIR)

STPARSER_ARM=$(ARM_DIR)/c-parser
STPARSER_ARM_HYP=$(ARM_HYP_DIR)/c-parser
STPARSER_X64=$(X64_DIR)/c-parser
STPARSERS=$(STPARSER_ARM) $(STPARSER_ARM_HYP) $(STPARSER_X64)

TOKENIZER_ARM=$(ARM_DIR)/tokenizer
TOKENIZER_ARM_HYP=$(ARM_HYP_DIR)/tokenizer
TOKENIZER_X64=$(X64_DIR)/tokenizer
TOKENIZERS=$(TOKENIZER_ARM) $(TOKENIZER_ARM_HYP) $(TOKENIZER_X64)

.PHONY: all cparser_tools stp_all standalone-cparser standalone-tokenizer

all: stp_all

standalone-cparser stp_all: $(STPARSERS)
standalone-tokenizer stp_all: $(TOKENIZERS)

include $(STP_PFX)/../Makefile

# This is only used for ARM_HYP and ARM since the former is a copy of the latter
UMM_HEAP_ARM_HYP=$(realpath $(STP_PFX)/../umm_heap)/ARM_HYP
UMM_HEAP_ARM=$(realpath $(STP_PFX)/../umm_heap/ARM)

$(UMM_HEAP_ARM_HYP)/% : $(UMM_HEAP_ARM)/%
	mkdir -p $(UMM_HEAP_ARM_HYP)
	cp -p $< $@

STP_CLEAN_TARGETS := $(STPARSERS) $(TOKENIZERS) $(STP_PFX)/c-parser.o $(STP_PFX)/table.ML

$(STP_PFX)/table.ML: $(ISABELLE_HOME)/src/Pure/General/table.ML
	sed -e '/ML.pretty-printing/,/final.declarations/d' < $< > $@

$(ARCH_DIRS):
	mkdir -p $@


ifeq ($(SML_COMPILER),mlton)
#
# compilation if the compiler is mlton
#

ARM_MLB_PATH := -mlb-path-var 'L4V_ARCH ARM'
ARM_HYP_MLB_PATH := -mlb-path-var 'L4V_ARCH ARM_HYP'
X64_MLB_PATH := -mlb-path-var 'L4V_ARCH X64'

PARSER_DEPS_ARM := $(shell mlton $(ARM_MLB_PATH) -stop f $(STP_PFX)/c-parser.mlb)
PARSER_DEPS_ARM_HYP := $(shell mlton $(ARM_HYP_MLB_PATH) -stop f $(STP_PFX)/c-parser.mlb)
PARSER_DEPS_X64 := $(shell mlton $(X64_MLB_PATH) -stop f $(STP_PFX)/c-parser.mlb)

TOKENIZER_DEPS_ARM := $(shell mlton $(ARM_MLB_PATH) -stop f $(STP_PFX)/tokenizer.mlb)
TOKENIZER_DEPS_ARM_HYP := $(shell mlton $(ARM_HYP_MLB_PATH) -stop f $(STP_PFX)/tokenizer.mlb)
TOKENIZER_DEPS_X64 := $(shell mlton $(X64_MLB_PATH) -stop f $(STP_PFX)/tokenizer.mlb)


$(STPARSER_ARM): $(PARSER_DEPS_ARM) | $(ARM_DIR)
	mlton $(ARM_MLB_PATH) -output $@ $<

$(STPARSER_ARM_HYP): $(PARSER_DEPS_ARM_HYP) | $(ARM_HYP_DIR)
	mlton $(ARM_HYP_MLB_PATH) -output $@ $<

$(STPARSER_X64): $(PARSER_DEPS_X64) | $(X64_DIR)
	mlton $(X64_MLB_PATH) -output $@ $<

$(TOKENIZER_ARM): $(TOKENIZER_DEPS_ARM) | $(ARM_DIR)
	mlton $(ARM_MLB_PATH) -output $@ $<

$(TOKENIZER_ARM_HYP): $(TOKENIZER_DEPS_ARM_HYP) | $(ARM_HYP_DIR)
	mlton $(ARM_HYP_MLB_PATH) -output $@ $<

$(TOKENIZER_X64): $(TOKENIZER_DEPS_X64) | $(X64_DIR)
	mlton $(X64_MLB_PATH) -output $@ $<


else ifeq ($(SML_COMPILER),poly)
#
# compilation with polyml may be bit-rotted
#

PARSER0_DEPS := $(shell perl -e 'use Cwd "abs_path"; while (<>) { if (/ml$$|sig$$/i && !/^ *mlton/) { tr/ //d; print abs_path("$(STP_PFX)/$$_"); }}' < $(STP_PFX)/c-parser.mlb)
PARSER_DEPS := $(PARSER0_DEPS) $(realpath $(STP_PFX)/c-parser.mlb) $(STP_PFX)/table.ML

TOKENIZER0_DEPS := $(shell perl -e 'use Cwd "abs_path"; while (<>) { if (/ml$$|sig$$/i && !/^ *mlton/) { tr/ //d; print abs_path("$(STP_PFX)/$$_"); }}' < $(STP_PFX)/tokenizer.mlb)
TOKENIZER_DEPS := $(TOKENIZER0_DEPS) $(realpath $(STP_PFX)/tokenzier.mlb) $(STP_PFX)/table.ML

$(STPARSER): $(STP_PFX)/c-parser.o $(LIBPOLYML)
	$(POLYCC) -o $@ $<

$(STP_PFX)/c-parser.o: $(STP_PFX)/poly-cparser.ML $(PARSER_DEPS)
	STP_PFX=$(STP_PFX) $(POLY) < $<

$(STP_PFX)/tokenizer: $(STP_PFX)/tokenizer.o $(LIBPOLYML)
	$(POLYCC) -o $@ $<

$(STP_PFX)/tokenizer.o: $(STP_PFX)/poly-tokenizer.ML $(TOKENIZER_DEPS)
	STP_PFX=$(STP_PFX) $(POLY) < $<


.PHONY: stp_deps
stp_deps:
	@echo $(PARSER_DEPS)

else
$(error Can only cope with SML_COMPILER as "poly" or "mlton"; got $(SML_COMPILER))

endif


clean: stp_clean

stp_clean:
	-/bin/rm -f $(STP_CLEAN_TARGETS)
	-/bin/rm -fr $(UMM_HEAP_ARM_HYP)

endif
