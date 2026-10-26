/* SPDX-License-Identifier: MIT
 * Host compilation proof for metadata-authenticated stock QC shader families.
 * A5_FAMILY_CONFIG is generated privately by misc_compile.py. No stock AIR or
 * executable bytes are embedded in this source. This is not device integration.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "compiler/glsl_types.h"
#include "compiler/spirv/nir_spirv.h"
#include "compiler/nir/nir_builder.h"
#include "compiler/nir/nir_lower_blend.h"
#include "panfrost/compiler/pan_compiler.h"
#include "misc_resource_lowering.h"
#include "misc_native_rt.h"
#ifndef A5_NATIVE_RGBA16
#define A5_NATIVE_RGBA16 0
#endif
#ifndef A5_INLINE_RGBA16_BLEND
#define A5_INLINE_RGBA16_BLEND 0
#endif
#ifndef A5_SELECTED_RT
#define A5_SELECTED_RT 0
#endif
#ifdef NDEBUG
#error Active NIR validation is required
#endif
#ifndef A5_FAMILY_CONFIG
#error Provide a generated authenticated metadata profile
#endif
struct a5_spec_value { uint32_t id, value; };
struct a5_texture_binding { unsigned binding, hardware; };
struct a5_stage_profile {
   uint64_t fingerprint;
   const struct a5_resource_binding *bindings;
   unsigned binding_count;
   const struct a5_spec_value *spec;
   unsigned spec_count;
   const struct a5_texture_binding *textures;
   unsigned texture_count;
   unsigned push_bytes;
};
#include A5_FAMILY_CONFIG
#include "misc_dynamic.h"
/* A Vulkan SubpassData read is Metal's current pixel, not an ordinary texture.
 * Map only the reflected, float, single-sample color0 read at offset(0,0).
 * Released Midgard emits TARGET_TILEBUF_WAIT for outputs_read before executing
 * ld_special on T720. Runtime must preload the target and preserve raster order.
 */
struct a5_fetch_lowering { const struct a5_dynamic_profile *profile; bool invalid; };
static bool lower_framebuffer_fetch(nir_builder *b,nir_intrinsic_instr *in,void *data)
{
   struct a5_fetch_lowering *ctx=data;
   if(in->intrinsic!=nir_intrinsic_image_deref_load)return false;
   nir_deref_instr *deref=nir_src_as_deref(in->src[0]);
   if(!glsl_type_is_image(deref->type))return false;
   enum glsl_sampler_dim dim=glsl_get_sampler_dim(deref->type);
   if(dim!=GLSL_SAMPLER_DIM_SUBPASS && dim!=GLSL_SAMPLER_DIM_SUBPASS_MS)return false;
   nir_variable *var=nir_deref_instr_get_variable(deref);
   /* SPIR-V image coordinates are widened to int4 with undef trailing lanes.
    * Only SubpassData's two actual offset lanes participate in this contract. */
   nir_scalar x=nir_scalar_resolved(in->src[1].ssa,0);
   nir_scalar y=nir_scalar_resolved(in->src[1].ssa,1);
   if(!ctx->profile->framebuffer_fetch_binding || dim!=GLSL_SAMPLER_DIM_SUBPASS ||
      deref->deref_type!=nir_deref_type_var || var->data.descriptor_set || var->data.index ||
      var->data.binding+1!=ctx->profile->framebuffer_fetch_binding ||
      glsl_get_sampler_result_type(deref->type)!=GLSL_TYPE_FLOAT ||
      in->def.num_components!=4 || in->def.bit_size!=32 ||
      !nir_scalar_is_const(x) || !nir_scalar_is_const(y) ||
      nir_scalar_as_uint(x) || nir_scalar_as_uint(y)){
      fprintf(stderr,"unsupported dynamic framebuffer fetch ABI binding=%u reflected=%u set=%u color=%u dimension=%u deref=%u type=%u shape=%u/%u constant_coord=%u\n",
         var->data.binding,ctx->profile->framebuffer_fetch_binding,var->data.descriptor_set,
         var->data.index,dim,deref->deref_type,glsl_get_sampler_result_type(deref->type),
         in->def.num_components,in->def.bit_size,nir_src_is_const(in->src[1]));
      ctx->invalid=true;return false;
   }
   b->cursor=nir_before_instr(&in->instr);
   nir_def *pixel=nir_load_output(b,4,32,nir_imm_int(b,0),.base=0,
      .io_semantics.location=FRAG_RESULT_DATA0,.io_semantics.num_slots=1,
      .dest_type=nir_type_float32);
   nir_def_replace(&in->def,pixel);
   return true;
}
#ifndef A5_PROFILE_COUNT
#define A5_PROFILE_COUNT 2
#endif
static unsigned type_size(const struct glsl_type *type, bool bindless)
{ (void)bindless; return glsl_count_attribute_slots(type, false); }
static uint64_t fingerprint(const void *data, size_t size)
{
   const uint8_t *p = data;
   uint64_t h = UINT64_C(0xcbf29ce484222325);
   for (size_t i = 0; i < size; ++i)
      h = (h ^ p[i]) * UINT64_C(0x100000001b3);
   return h;
}
static uint32_t *read_module(const char *path, size_t *size)
{
   FILE *f = fopen(path, "rb");
   if (!f) return NULL;
   if (fseek(f, 0, SEEK_END)) { fclose(f); return NULL; }
   long length = ftell(f);
   if (length < 20 || length > 16*1024*1024 || (length & 3) ||
       fseek(f, 0, SEEK_SET)) { fclose(f); return NULL; }
   uint32_t *words = malloc(length);
   if (!words) { fclose(f); return NULL; }
   if (fread(words, 1, length, f) != (size_t)length) {
      free(words); words = NULL;
   }
   fclose(f); *size = length; return words;
}
struct lowering { const struct a5_stage_profile *profile; bool invalid; };
static bool select_target(nir_builder *b,nir_intrinsic_instr *intr,void *data)
{
   (void)b;(void)data;
   if(intr->intrinsic!=nir_intrinsic_store_output)return false;
   nir_io_semantics sem=nir_intrinsic_io_semantics(intr);
   if(sem.location<FRAG_RESULT_DATA0)return false;
   if(sem.location!=FRAG_RESULT_DATA0+A5_SELECTED_RT){
      nir_instr_remove(&intr->instr);return true;
   }
   sem.location=FRAG_RESULT_DATA0;
   nir_intrinsic_set_io_semantics(intr,sem);
   nir_intrinsic_set_base(intr,0);
   return true;
}
static bool lower_push(nir_builder *b, nir_intrinsic_instr *intr, void *data)
{
   struct lowering *ctx = data;
   if (intr->intrinsic != nir_intrinsic_load_push_constant) return false;
   b->cursor = nir_before_instr(&intr->instr);
   nir_def *value = nir_load_ubo(b, intr->def.num_components,
      intr->def.bit_size, nir_imm_int(b, 0), intr->src[0].ssa,
      .range = ctx->profile->push_bytes, .align_mul = 4);
   nir_def_rewrite_uses(&intr->def, value); return true;
}
static bool lower_half(nir_builder *b, nir_alu_instr *alu, void *data)
{
   (void)data;
   if (alu->op != nir_op_fquantize2f16) return false;
   b->cursor = nir_before_instr(&alu->instr);
   nir_def_replace(&alu->def, nir_f2f32(b, nir_f2f16(b, nir_ssa_for_alu_src(b,alu,0))));
   return true;
}
struct a5_fragcoord_lowering { unsigned base; };
/* Driver locations are assigned before dead varyings are optimized away. Keep
 * that descriptor ABI: FragCoord follows the entire original input extent,
 * rather than reusing a dead slot or assuming that a shader has two inputs.
 * A dual-UV shader also exports color at base 2, so a literal 2 aliases it.
 */
static bool a5_fragcoord_layout(nir_shader *nir,struct a5_fragcoord_lowering *out)
{
   unsigned end=0;
   nir_foreach_shader_in_variable(var,nir){
      if(var->data.location<VARYING_SLOT_VAR0)continue;
      unsigned slots=glsl_count_attribute_slots(var->type,false);
      unsigned base=var->data.driver_location;
      if(!slots || base>=A5_DYNAMIC_MAX_IO || slots>A5_DYNAMIC_MAX_IO-base){
         fprintf(stderr,"dynamic fragment declared varying extent base=%u slots=%u\n",base,slots);
         return false;
      }
      end=MAX2(end,base+slots);
   }
   nir_foreach_function_impl(impl,nir){nir_foreach_block(block,impl){nir_foreach_instr(instr,block){
      if(instr->type!=nir_instr_type_intrinsic)continue;
      nir_intrinsic_instr *in=nir_instr_as_intrinsic(instr);
      if(in->intrinsic!=nir_intrinsic_load_input &&
         in->intrinsic!=nir_intrinsic_load_interpolated_input)continue;
      nir_io_semantics sem=nir_intrinsic_io_semantics(in);
      unsigned base=nir_intrinsic_base(in);
      if(!sem.num_slots || base>=A5_DYNAMIC_MAX_IO ||
         sem.num_slots>A5_DYNAMIC_MAX_IO-base){
         fprintf(stderr,"dynamic fragment varying extent base=%u slots=%u\n",base,sem.num_slots);
         return false;
      }
      end=MAX2(end,base+sem.num_slots);
   }}}
   /* One further slot is needed only when FragCoord is actually present. */
   nir_foreach_function_impl(impl,nir){nir_foreach_block(block,impl){nir_foreach_instr(instr,block){
      if(instr->type==nir_instr_type_intrinsic &&
         nir_instr_as_intrinsic(instr)->intrinsic==nir_intrinsic_load_frag_coord &&
         end>=A5_DYNAMIC_MAX_IO){
         fprintf(stderr,"dynamic fragment position has no free varying slot\n");
         return false;
      }
   }}}
   out->base=end;return true;
}
static bool lower_fragcoord(nir_builder *b, nir_intrinsic_instr *intr, void *data)
{
   const struct a5_fragcoord_lowering *layout=data;
   if (intr->intrinsic != nir_intrinsic_load_frag_coord) return false;
   b->cursor = nir_before_instr(&intr->instr);
   nir_def *value = nir_load_input(b,4,32,nir_imm_int(b,0),.base=layout?layout->base:0,
      .io_semantics.location=VARYING_SLOT_POS,.io_semantics.num_slots=1,
      .dest_type=nir_type_float32);
   nir_def_rewrite_uses(&intr->def,value); return true;
}
/* Mesa26.2.4 Midgard's mir_derivative_mode maps each fine/coarse/default
 * family to the same hardware derivative mode. Its NIR dispatcher only
 * accepts the default spelling. Canonicalize that existing hardware mapping
 * before dispatch instead of letting a valid fine derivative hit its assert.
 * The texture derivative pipe operates on float32; preserve half precision
 * at the boundary with explicit conversions.
 */
static bool lower_derivative(nir_builder *b,nir_intrinsic_instr *in,void *data)
{
   struct lowering *ctx=data;
   bool dx;
   switch(in->intrinsic){
   case nir_intrinsic_ddx:case nir_intrinsic_ddx_fine:case nir_intrinsic_ddx_coarse:dx=true;break;
   case nir_intrinsic_ddy:case nir_intrinsic_ddy_fine:case nir_intrinsic_ddy_coarse:dx=false;break;
   default:return false;
   }
   if(b->shader->info.stage!=MESA_SHADER_FRAGMENT ||
      !in->def.num_components || in->def.num_components>4 ||
      (in->def.bit_size!=16 && in->def.bit_size!=32) ||
      nir_src_num_components(in->src[0])!=in->def.num_components ||
      nir_src_bit_size(in->src[0])!=in->def.bit_size){
      fprintf(stderr,"unsupported Midgard derivative shape\n");ctx->invalid=true;return false;
   }
   if(in->def.bit_size==32){
      nir_intrinsic_op canonical=dx?nir_intrinsic_ddx:nir_intrinsic_ddy;
      if(in->intrinsic==canonical)return false;
      in->intrinsic=canonical;return true;
   }
   b->cursor=nir_before_instr(&in->instr);
   nir_def *source=nir_f2f32(b,in->src[0].ssa);
   nir_def *value=dx?nir_ddx(b,source):nir_ddy(b,source);
   nir_def_replace(&in->def,nir_f2f16(b,value));return true;
}
static bool lower_texture(nir_builder *b, nir_instr *instr, void *data)
{
   struct lowering *ctx = data;
   if (instr->type != nir_instr_type_tex) return false;
   nir_tex_instr *tex = nir_instr_as_tex(instr);
   int index = nir_tex_instr_src_index(tex,nir_tex_src_texture_deref);
   if (index < 0) { fprintf(stderr,"texture lacks descriptor deref op=%u\n",tex->op);ctx->invalid=true; return false; }
   nir_deref_instr *deref = nir_src_as_deref(tex->src[index].src);
   nir_variable *var = nir_deref_instr_get_variable(deref);
   const struct a5_texture_binding *binding = NULL;
   for (unsigned i=0;i<ctx->profile->texture_count;++i)
      if (ctx->profile->textures[i].binding == var->data.binding)
         binding=&ctx->profile->textures[i];
   while (deref->deref_type==nir_deref_type_cast && nir_deref_instr_parent(deref))
      deref=nir_deref_instr_parent(deref);
   if (!binding || deref->deref_type != nir_deref_type_var || var->data.descriptor_set) {
      fprintf(stderr,"unsupported texture binding=%u deref=%u set=%u\n",var->data.binding,deref->deref_type,var->data.descriptor_set);ctx->invalid=true; return false;
   }
   tex->texture_index=binding->hardware;
   nir_tex_instr_remove_src(tex,index);
   index=nir_tex_instr_src_index(tex,nir_tex_src_sampler_deref);
   if (index>=0) {
      nir_deref_instr *sampler = nir_src_as_deref(tex->src[index].src);
      nir_variable *sv = nir_deref_instr_get_variable(sampler);
      while (sampler->deref_type==nir_deref_type_cast && nir_deref_instr_parent(sampler))
         sampler=nir_deref_instr_parent(sampler);
      if (sampler->deref_type!=nir_deref_type_var || sv->data.binding!=binding->binding) {
         fprintf(stderr,"sampler differs from combined texture\n");ctx->invalid=true; return false;
      }
      tex->sampler_index=binding->hardware;
      nir_tex_instr_remove_src(tex,index);
   }
   if (tex->op == nir_texop_query_levels || tex->op == nir_texop_txs) {
      /* Runtime UBO0 texture records start352, stride32: levels,width,height,
       * reserved, minLOD,maxLOD,bias,reserved. Distinct resources stay distinct. */
      unsigned offset=352+32*binding->hardware+(tex->op==nir_texop_txs?4:0);
      b->cursor=nir_before_instr(instr);
      nir_def_rewrite_uses(&tex->def,nir_load_ubo(b,tex->def.num_components,
         tex->def.bit_size,nir_imm_int(b,0),nir_imm_int(b,offset),
         .range_base=offset,.range=tex->def.num_components*4,.align_mul=4));
   }
   return true;
}

#include "misc_anisotropy.h"

static bool lower_sysvals(nir_builder *b,nir_intrinsic_instr *intr,void *data)
{
   struct lowering *ctx=data;
   unsigned offset, count;
   if (intr->intrinsic==nir_intrinsic_load_viewport_scale ||
       intr->intrinsic==nir_intrinsic_load_viewport_offset) {
      offset=intr->intrinsic==nir_intrinsic_load_viewport_scale?512:528;
      count=3;
   } else if (intr->intrinsic==nir_intrinsic_load_raw_vertex_offset_pan) {
      offset=544; count=1;
   } else if (intr->intrinsic==nir_intrinsic_load_base_vertex) {
      offset=548; count=1;
   } else if (intr->intrinsic==nir_intrinsic_load_base_instance) {
      offset=552; count=1;
   } else if (intr->intrinsic==nir_intrinsic_load_blend_const_color_rgba) {
      if(b->shader->info.stage!=MESA_SHADER_FRAGMENT){ctx->invalid=true;return false;}
      offset=480;count=4;
   } else if (intr->intrinsic==nir_intrinsic_load_sampler_lod_parameters) {
      if (!nir_src_is_const(intr->src[0]) ||
          nir_src_as_uint(intr->src[0])>=ctx->profile->texture_count) {
         ctx->invalid=true;return false;
      }
      offset=352+32*nir_src_as_uint(intr->src[0])+16; count=3;
   } else return false;
   if (intr->def.num_components!=count || intr->def.bit_size!=32) {
      ctx->invalid=true;return false;
   }
   b->cursor=nir_before_instr(&intr->instr);
   nir_def_replace(&intr->def,nir_load_ubo(b,count,32,nir_imm_int(b,0),
      nir_imm_int(b,offset),.range_base=offset,.range=count*4,.align_mul=4));
   return true;
}
static int compile(const char *input,const char *output,mesa_shader_stage stage,
                   const struct a5_dynamic_profile *dynamic,const char *info_path)
{
   size_t bytes=0;
   uint32_t *words=read_module(input,&bytes);
   if (!words || words[0]!=0x07230203) {
      fprintf(stderr,"module differs from authenticated family profile\n");free(words);return 2;
   }
   uint64_t module_fingerprint=fingerprint(words,bytes);
   const struct a5_stage_profile *profile=dynamic?&dynamic->profile:NULL;
   unsigned stage_index=stage==MESA_SHADER_VERTEX?0:1;
   for(unsigned i=stage_index;!profile && i<A5_PROFILE_COUNT;i+=2)
      if(kStages[i].fingerprint==module_fingerprint){profile=&kStages[i];break;}
   if(!profile){
      fprintf(stderr,"module differs from authenticated family profile\n");free(words);return 2;
   }
   struct nir_spirv_specialization_entry entries[16]={0};
   if(profile->spec_count>16)return 2;
   for(unsigned i=0;i<profile->spec_count;++i){
      entries[i].id=profile->spec[i].id;entries[i].size=4;
      entries[i].data=(void*)&profile->spec[i].value;
   }
   struct nir_spirv_specialization spec={.num_entries=profile->spec_count,.entries=entries};
   struct spirv_to_nir_options opts={.environment=NIR_SPIRV_VULKAN,
      .ubo_addr_format=nir_address_format_32bit_index_offset,
      .ssbo_addr_format=nir_address_format_32bit_index_offset,
      .phys_ssbo_addr_format=nir_address_format_64bit_global,
      .shared_addr_format=nir_address_format_32bit_offset,
      .min_ubo_alignment=16,.min_ssbo_alignment=16};
   nir_shader *nir=spirv_to_nir(words,bytes/4,&spec,stage,"main",&opts,
      pan_get_nir_shader_compiler_options(4,stage,false));
   free(words);if(!nir)return 2;
   nir_validate_shader(nir,"family SPIR-V");
   if(dynamic){
      NIR_PASS(_,nir,nir_opt_deref);
      NIR_PASS(_,nir,nir_opt_constant_folding);
      NIR_PASS(_,nir,nir_opt_copy_prop);
      struct a5_fetch_lowering fetch={.profile=dynamic};
      NIR_PASS(_,nir,nir_shader_intrinsics_pass,lower_framebuffer_fetch,
         nir_metadata_control_flow,&fetch);
      if(fetch.invalid){ralloc_free(nir);return 2;}
      nir_validate_shader(nir,"dynamic ordered tilebuffer fetch");
   }
   NIR_PASS(_,nir,nir_lower_system_values);
   if(stage==MESA_SHADER_FRAGMENT)NIR_PASS(_,nir,nir_lower_wpos_center);
   NIR_PASS(_,nir,nir_lower_explicit_io,nir_var_mem_push_const,nir_address_format_32bit_offset);
   nir_assign_io_var_locations(nir,nir_var_shader_in);
   nir_assign_io_var_locations(nir,nir_var_shader_out);
   NIR_PASS(_,nir,nir_lower_var_copies);
   NIR_PASS(_,nir,nir_lower_indirect_derefs_to_if_else_trees,
      nir_var_shader_in|nir_var_shader_out,UINT32_MAX);
   NIR_PASS(_,nir,nir_lower_io,nir_var_shader_in|nir_var_shader_out,
      type_size,nir_lower_io_use_interpolated_input_intrinsics);
   if(stage==MESA_SHADER_FRAGMENT && !dynamic)
      NIR_PASS(_,nir,nir_shader_intrinsics_pass,select_target,nir_metadata_control_flow,NULL);
   NIR_PASS(_,nir,nir_opt_constant_folding);
   struct a5_fragcoord_lowering fragcoord={0};
   if(dynamic && stage==MESA_SHADER_FRAGMENT && !a5_fragcoord_layout(nir,&fragcoord)){
      ralloc_free(nir);return 2;
   }
   struct pan_compile_inputs inputs={.gpu_id=0x07201000,.is_blit=true,.no_idvs=true};
   struct pan_shader_info info={0};struct util_dynarray binary=UTIL_DYNARRAY_INIT;
   nir_shader_gather_info(nir,nir_shader_get_entrypoint(nir));
   struct pan_varying_layout varyings;
   if(stage==MESA_SHADER_VERTEX){
      pan_varying_collect_formats(&varyings,nir,inputs.gpu_id,false,false);
      pan_build_varying_layout_compact(&varyings,nir,inputs.gpu_id);
      inputs.varying_layout=&varyings;
   }
   NIR_PASS(_,nir,nir_lower_variable_initializers,
            nir_var_function_temp|nir_var_shader_temp);
   pan_preprocess_nir(nir,inputs.gpu_id);
   struct lowering ctx={.profile=profile};
   NIR_PASS(_,nir,nir_shader_instructions_pass,lower_texture,nir_metadata_control_flow,&ctx);
   if(dynamic&&stage==MESA_SHADER_FRAGMENT){
      NIR_PASS(_,nir,nir_shader_tex_pass,a5_lower_anisotropy,nir_metadata_none,NULL);
      NIR_PASS(_,nir,nir_lower_vars_to_ssa);
   }
   struct a5_resource_context resources={.bindings=profile->bindings,.count=profile->binding_count};
   NIR_PASS(_,nir,nir_shader_intrinsics_pass,a5_lower_resource_descriptor,nir_metadata_control_flow,&resources);
   NIR_PASS(_,nir,nir_lower_explicit_io,nir_var_mem_ubo|nir_var_mem_ssbo,nir_address_format_32bit_index_offset);
   NIR_PASS(_,nir,nir_opt_constant_folding);
   NIR_PASS(_,nir,nir_lower_ssbo,NULL);
   NIR_PASS(_,nir,nir_opt_copy_prop);
   NIR_PASS(_,nir,nir_opt_algebraic);
   NIR_PASS(_,nir,nir_opt_constant_folding);
   NIR_PASS(_,nir,nir_opt_copy_prop);
   NIR_PASS(_,nir,nir_shader_intrinsics_pass,a5_lower_ssbo_sysval,nir_metadata_control_flow,&resources);
   NIR_PASS(_,nir,nir_shader_intrinsics_pass,lower_push,nir_metadata_control_flow,&ctx);
   if(stage==MESA_SHADER_FRAGMENT)
      NIR_PASS(_,nir,nir_shader_intrinsics_pass,lower_fragcoord,nir_metadata_control_flow,dynamic?&fragcoord:NULL);
   NIR_PASS(_,nir,nir_shader_alu_pass,lower_half,nir_metadata_control_flow,NULL);
   NIR_PASS(_,nir,nir_shader_intrinsics_pass,lower_derivative,nir_metadata_control_flow,&ctx);
   NIR_PASS(_,nir,nir_opt_dce);
   if(resources.invalid||ctx.invalid){fprintf(stderr,"unsupported resource ABI\n");return 2;}
   nir_validate_shader(nir,"family real resource lowering");
   if(dynamic && dynamic->blend.enabled){
      static const enum pipe_blend_func operations[]={PIPE_BLEND_ADD,PIPE_BLEND_SUBTRACT,
         PIPE_BLEND_REVERSE_SUBTRACT,PIPE_BLEND_MIN,PIPE_BLEND_MAX};
      static const enum pipe_blendfactor factors[]={PIPE_BLENDFACTOR_ZERO,PIPE_BLENDFACTOR_ONE,
         PIPE_BLENDFACTOR_SRC_COLOR,PIPE_BLENDFACTOR_INV_SRC_COLOR,PIPE_BLENDFACTOR_SRC_ALPHA,
         PIPE_BLENDFACTOR_INV_SRC_ALPHA,PIPE_BLENDFACTOR_DST_COLOR,PIPE_BLENDFACTOR_INV_DST_COLOR,
         PIPE_BLENDFACTOR_DST_ALPHA,PIPE_BLENDFACTOR_INV_DST_ALPHA,PIPE_BLENDFACTOR_SRC_ALPHA_SATURATE,
         PIPE_BLENDFACTOR_CONST_COLOR,PIPE_BLENDFACTOR_INV_CONST_COLOR,PIPE_BLENDFACTOR_CONST_ALPHA,
         PIPE_BLENDFACTOR_INV_CONST_ALPHA};
      nir_lower_blend_options blend={0};
      blend.rt[0].format=dynamic->blend.format==80?PIPE_FORMAT_B8G8R8A8_UNORM:PIPE_FORMAT_B5G5R5A1_UNORM;
      unsigned m=dynamic->blend.mask;
      blend.rt[0].colormask=((m&8)>>3)|((m&4)>>1)|((m&2)<<1)|((m&1)<<3);
      blend.rt[0].rgb=(nir_lower_blend_channel){operations[dynamic->blend.rgb],factors[dynamic->blend.src_rgb],factors[dynamic->blend.dst_rgb]};
      blend.rt[0].alpha=(nir_lower_blend_channel){operations[dynamic->blend.alpha],factors[dynamic->blend.src_alpha],factors[dynamic->blend.dst_alpha]};
      NIR_PASS(_,nir,nir_lower_blend,&blend);
      nir_lower_single_sampled_options one_sample={0};
      NIR_PASS(_,nir,nir_lower_single_sampled,&one_sample);
      nir->info.fs.uses_sample_shading=false;
      nir_validate_shader(nir,"pipeline-dependent Metal blend lowering");
   }
   if(stage==MESA_SHADER_FRAGMENT && A5_INLINE_RGBA16_BLEND) {
      if(!A5_NATIVE_RGBA16 || A5_SELECTED_RT!=0){fprintf(stderr,"unreviewed inline blend target\n");return 2;}
      nir_lower_blend_options blend={0};
      blend.rt[0].format=PIPE_FORMAT_R16G16B16A16_FLOAT;
      blend.rt[0].colormask=15;
      blend.rt[0].rgb.func=blend.rt[0].alpha.func=PIPE_BLEND_ADD;
      blend.rt[0].rgb.src_factor=blend.rt[0].alpha.src_factor=PIPE_BLENDFACTOR_ONE;
      blend.rt[0].rgb.dst_factor=blend.rt[0].alpha.dst_factor=PIPE_BLENDFACTOR_INV_SRC_ALPHA;
      NIR_PASS(_,nir,nir_lower_blend,&blend);
      nir_lower_single_sampled_options one_sample={0};
      NIR_PASS(_,nir,nir_lower_single_sampled,&one_sample);
      nir->info.fs.uses_sample_shading=false;
      nir_validate_shader(nir,"actual QC RAW204 inline source-over");
   }
   if(stage==MESA_SHADER_FRAGMENT && A5_NATIVE_RGBA16)
      a5_lower_native_rgba16(nir);
   pan_postprocess_nir(nir,&inputs,&info);
   NIR_PASS(_,nir,nir_shader_intrinsics_pass,lower_sysvals,nir_metadata_control_flow,&ctx);
   if(ctx.invalid){fprintf(stderr,"unsupported sysval ABI\n");return 2;}
   nir_validate_shader(nir,"family postprocess");
   nir_shader_gather_info(nir,nir_shader_get_entrypoint(nir));
   /* Panfrost consumes both explicit UBO loads and shader_info's table
    * extent. The Vulkan-to-hardware remap reserves UBO0, so retaining the
    * original Vulkan UBO count would truncate the last actual descriptor. */
   nir->info.num_ubos=1;
   for(unsigned i=0;i<profile->binding_count;++i)
      if(profile->bindings[i].type==nir_descriptor_type_uniform_buffer)
         nir->info.num_ubos=MAX2(nir->info.num_ubos,profile->bindings[i].binding+2);
   BITSET_ZERO(nir->info.textures_used);
   nir_foreach_function_impl(impl,nir) {
      nir_foreach_block(block,impl) {
         nir_foreach_instr(instr,block) {
            if(instr->type!=nir_instr_type_tex)continue;
            nir_tex_instr *tex=nir_instr_as_tex(instr);
            if(tex->texture_index>=profile->texture_count){
               fprintf(stderr,"final texture index outside authenticated ABI\n");return 2;
            }
            BITSET_SET(nir->info.textures_used,tex->texture_index);
         }
      }
   }
   struct a5_dynamic_info dynamic_info={0};
   /* A compositor specialization can contain megabytes of pre-optimized NIR
    * yet emit a kilobyte of native code. Dumping it synchronously to the phone
    * competes with shader paging and stalls the waiting compositor. Keep all
    * validation and native metadata; full IR is an explicit compiler-only
    * diagnostic, never selected by a shader request or a supplied file path.
    */
   const char *dump_nir=getenv("A5_MIDGARD_DUMP_NIR");
   bool dump=dump_nir && !strcmp(dump_nir,"1");
   fprintf(stderr,"Midgard NIR: stage=%s validation=enabled dump=%u\n",
      mesa_shader_stage_name(stage),dump);
   if(dump)nir_print_shader(nir,stdout);
   pan_shader_compile(nir,&inputs,&binary,&info);
   /* Midgard's optimizer eliminates inactive constant-blob/storage branches.
    * Analyze the actual optimized program, never declarations or an earlier
    * unoptimized AIR translation, before publishing any executable bytes. */
   if(dynamic && !a5_dynamic_analyze(nir,dynamic,&dynamic_info)){
      fprintf(stderr,"unsupported dynamic live resource or IO ABI\n");
      util_dynarray_fini(&binary);ralloc_free(nir);return 2;
   }
   if(dynamic && (!binary.size || binary.size>(stage==MESA_SHADER_FRAGMENT?16384u:8192u) || info.tls_size || info.wls_size ||
      info.work_reg_count>16 || info.texture_count>4 || info.ubo_count>8)){
      fprintf(stderr,"unsupported dynamic native limits bytes=%u tls=%u wls=%u regs=%u textures=%u ubos=%u\n",
         binary.size,info.tls_size,info.wls_size,info.work_reg_count,info.texture_count,info.ubo_count);
      util_dynarray_fini(&binary);ralloc_free(nir);return 2;
   }
   FILE *f=fopen(output,"wb");
   int rc=1;
   if(f && binary.size && fwrite(binary.data,1,binary.size,f)==binary.size){
      rc=fclose(f);f=NULL;
      printf("%s: Midgard bytes=%u first_tag=%u textures=%u work_regs=%u tls=%u wls=%u attributes=%u ubos=%u samplers=%u\n",
         output,binary.size,info.midgard.first_tag,info.texture_count,info.work_reg_count,
         info.tls_size,info.wls_size,info.attribute_count,info.ubo_count,info.sampler_count);
   }
   if(f)fclose(f);
   if(!rc && dynamic && !a5_dynamic_write(info_path,stage,&info,binary.size,&dynamic_info,dynamic))rc=2;
   if(rc && dynamic){remove(output);remove(info_path);}
   util_dynarray_fini(&binary);ralloc_free(nir);return rc;
}
int main(int argc,char**argv)
{
   if(argc==7 && !strcmp(argv[1],"--dynamic-stage")){
      mesa_shader_stage stage;
      if(!strcmp(argv[2],"vertex"))stage=MESA_SHADER_VERTEX;
      else if(!strcmp(argv[2],"fragment"))stage=MESA_SHADER_FRAGMENT;
      else return 2;
      struct a5_dynamic_profile profile;
      if(!a5_dynamic_read(argv[5],stage,&profile)){
         fprintf(stderr,"invalid dynamic reflected ABI manifest\n");return 2;
      }
      glsl_type_singleton_init_or_ref();
      int rc=compile(argv[3],argv[4],stage,&profile,argv[6]);
      glsl_type_singleton_decref();return rc;
   }
   if(argc!=5){fprintf(stderr,"usage: %s vert.spv frag.spv vert.bin frag.bin\n",argv[0]);return 2;}
   glsl_type_singleton_init_or_ref();
   int rc=compile(argv[1],argv[3],MESA_SHADER_VERTEX,NULL,NULL);
   if(!rc)rc=compile(argv[2],argv[4],MESA_SHADER_FRAGMENT,NULL,NULL);
   glsl_type_singleton_decref();return rc;
}
