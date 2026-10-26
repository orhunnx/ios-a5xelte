/* SPDX-License-Identifier: MIT
 * Bounded reflected ABI for dynamically translated QuartzCore stages.
 * The caller validates SPIR-V and derives this manifest from translator
 * reflection. This parser never substitutes a shader/module fingerprint.
 */
#ifndef A5_MISC_DYNAMIC_H
#define A5_MISC_DYNAMIC_H
#define A5_DYNAMIC_MAX_BINDINGS 16
#define A5_DYNAMIC_MAX_TEXTURES 4
#define A5_DYNAMIC_MAX_IO 32
struct a5_dynamic_profile {
   struct a5_stage_profile profile;
   struct a5_resource_binding bindings[A5_DYNAMIC_MAX_BINDINGS];
   unsigned binding_bytes[A5_DYNAMIC_MAX_BINDINGS];
   struct a5_spec_value specs[16];
   struct a5_texture_binding textures[A5_DYNAMIC_MAX_TEXTURES];
   /* Descriptor binding+1, zero when the stage does not fetch color0. */
   unsigned framebuffer_fetch_binding;
   struct { unsigned enabled,format,mask,rgb,alpha,src_rgb,dst_rgb,src_alpha,dst_alpha; } blend;
};
struct a5_dynamic_io { unsigned location,base,component,components,bit_size; };
struct a5_dynamic_info {
   unsigned ubo_bytes[8],textures,framebuffer_fetch;
   struct a5_dynamic_io inputs[A5_DYNAMIC_MAX_IO],outputs[A5_DYNAMIC_MAX_IO];
   unsigned input_count,output_count;
};
static int a5_dynamic_read(const char *path,mesa_shader_stage stage,
                           struct a5_dynamic_profile *out)
{
   FILE *f=fopen(path,"rb");if(!f)return 0;
   char line[160];unsigned lines=0,got_stage=0,got_push=0;
   memset(out,0,sizeof(*out));
   if(!fgets(line,sizeof(line),f)||strcmp(line,"A5MIDGARD1\n")){fclose(f);return 0;}
   while(fgets(line,sizeof(line),f)){
      char key[32],kind[32],tail;unsigned a,b;
      if(++lines>64 || !strchr(line,'\n'))goto bad;
      /* scanf's unsigned conversion may wrap an out-of-range decimal.
       * Validate numeric tokens independently before applying field bounds. */
      char checked[160];memcpy(checked,line,strlen(line)+1);
      char *save=NULL;
      for(char *word=strtok_r(checked," \t\r\n",&save);word;word=strtok_r(NULL," \t\r\n",&save)){
         if(*word=='+'||*word=='-')goto bad;
         if(*word>='0'&&*word<='9'){
            if(strlen(word)>10)goto bad;
            uint64_t value=0;
            for(char *c=word;*c;c++){
               if(*c<'0'||*c>'9')goto bad;
               value=value*10+(unsigned)(*c-'0');
            }
            if(value>UINT32_MAX)goto bad;
         }
      }
      if(sscanf(line,"%31s",key)!=1)goto bad;
      if(!strcmp(key,"stage")){
         if(got_stage++ || sscanf(line,"stage %31s %c",kind,&tail)!=1 ||
            strcmp(kind,stage==MESA_SHADER_VERTEX?"vertex":"fragment"))goto bad;
      }else if(!strcmp(key,"push_bytes")){
         if(got_push++ || sscanf(line,"push_bytes %u %c",&a,&tail)!=1 || a>80 || (a&3))goto bad;
         out->profile.push_bytes=a;
      }else if(!strcmp(key,"binding")){
         unsigned n=out->profile.binding_count;
         if(n>=A5_DYNAMIC_MAX_BINDINGS || sscanf(line,"binding %u %31s %u %c",&a,kind,&b,&tail)!=3 ||
            a>=16 || (!strcmp(kind,"uniform")&&(a>=7 || !b || b>4096)) ||
            (strcmp(kind,"uniform")&&strcmp(kind,"storage")) || b>4096)goto bad;
         for(unsigned i=0;i<n;i++)if(out->bindings[i].binding==a)goto bad;
         out->bindings[n]=(struct a5_resource_binding){a,!strcmp(kind,"uniform")?
             nir_descriptor_type_uniform_buffer:nir_descriptor_type_storage_buffer};
         out->binding_bytes[n]=b;out->profile.binding_count++;
      }else if(!strcmp(key,"spec")){
         unsigned n=out->profile.spec_count;
         if(n>=16 || sscanf(line,"spec %u %u %c",&a,&b,&tail)!=2 || a>=256 || b>4096)goto bad;
         for(unsigned i=0;i<n;i++)if(out->specs[i].id==a)goto bad;
         out->specs[n]=(struct a5_spec_value){a,b};out->profile.spec_count++;
      }else if(!strcmp(key,"texture")){
         unsigned n=out->profile.texture_count;
         if(n>=A5_DYNAMIC_MAX_TEXTURES || sscanf(line,"texture %u %u %c",&a,&b,&tail)!=2 ||
            a>=32 || b!=n)goto bad;
         for(unsigned i=0;i<n;i++)if(out->textures[i].binding==a)goto bad;
         out->textures[n]=(struct a5_texture_binding){a,b};out->profile.texture_count++;
      }else if(!strcmp(key,"blend")){
         unsigned format,mask,rgb,alpha,sr,dr,sa,da;
         if(stage!=MESA_SHADER_FRAGMENT || out->blend.enabled ||
            sscanf(line,"blend %u %u %u %u %u %u %u %u %c",
             &format,&mask,&rgb,&alpha,&sr,&dr,&sa,&da,&tail)!=8 ||
            (format!=80&&format!=43)||mask>15||rgb>4||alpha>4||sr>14||dr>14||sa>14||da>14)goto bad;
         out->blend.enabled=1;out->blend.format=format;out->blend.mask=mask;
         out->blend.rgb=rgb;out->blend.alpha=alpha;
         out->blend.src_rgb=sr;out->blend.dst_rgb=dr;out->blend.src_alpha=sa;out->blend.dst_alpha=da;
      }else if(!strcmp(key,"framebuffer_fetch")){
         if(stage!=MESA_SHADER_FRAGMENT || out->framebuffer_fetch_binding ||
            sscanf(line,"framebuffer_fetch %u %u %c",&a,&b,&tail)!=2 || a>=32 || b)
            goto bad;
         out->framebuffer_fetch_binding=a+1;
      }else goto bad;
   }
   if(ferror(f)||!got_stage||!got_push)goto bad;
   fclose(f);out->profile.bindings=out->bindings;out->profile.spec=out->specs;
   out->profile.textures=out->textures;return 1;
 bad:fclose(f);return 0;
}
static int a5_dynamic_io_add(struct a5_dynamic_io *list,unsigned *count,
                             nir_intrinsic_instr *intr,bool output)
{
   unsigned offset_src=intr->intrinsic==nir_intrinsic_load_interpolated_input?1:0;
   if(output)offset_src=1;
   if(!nir_src_is_const(intr->src[offset_src]) || nir_src_as_uint(intr->src[offset_src])){fprintf(stderr,"dynamic varying offset\n");return 0;}
   struct a5_dynamic_io v={nir_intrinsic_io_semantics(intr).location,
      nir_intrinsic_base(intr),nir_intrinsic_component(intr),
      output?nir_src_num_components(intr->src[0]):intr->def.num_components,
      output?nir_src_bit_size(intr->src[0]):intr->def.bit_size};
   if(v.components>4 || v.bit_size!=32 || v.component+v.components>4){fprintf(stderr,"dynamic varying shape %u/%u/%u\n",v.components,v.bit_size,v.component);return 0;}
   for(unsigned i=0;i<*count;i++)if(!memcmp(list+i,&v,sizeof(v)))return 1;
   if(*count>=A5_DYNAMIC_MAX_IO)return 0;
   list[(*count)++]=v;return 1;
}
static int a5_dynamic_analyze(nir_shader *nir,const struct a5_dynamic_profile *profile,
                              struct a5_dynamic_info *info)
{
   memset(info,0,sizeof(*info));
   nir_foreach_function_impl(impl,nir){nir_foreach_block(block,impl){nir_foreach_instr(instr,block){
      if(instr->type==nir_instr_type_tex){
         nir_tex_instr *t=nir_instr_as_tex(instr);
         if(t->texture_index>=profile->profile.texture_count || t->sampler_dim!=GLSL_SAMPLER_DIM_2D ||
            t->is_array || t->is_shadow ||
            (t->op!=nir_texop_tex && t->op!=nir_texop_txb &&
             t->op!=nir_texop_txl && t->op!=nir_texop_txd)){fprintf(stderr,"dynamic texture op=%u dimension=%u\n",t->op,t->sampler_dim);return 0;}
         info->textures|=1u<<t->texture_index;continue;
      }
      if(instr->type!=nir_instr_type_intrinsic)continue;
      nir_intrinsic_instr *in=nir_instr_as_intrinsic(instr);
      const char *name=nir_intrinsic_infos[in->intrinsic].name;
      if(strstr(name,"global")||strstr(name,"ssbo")||strstr(name,"image")||
         strstr(name,"shared")||strstr(name,"atomic")||strstr(name,"barrier")||
         strstr(name,"discard")||strstr(name,"terminate")||strstr(name,"demote")){fprintf(stderr,"dynamic unsupported intrinsic %s\n",name);return 0;}
      if(in->intrinsic==nir_intrinsic_load_ubo){
         if(!nir_src_is_const(in->src[0])||!nir_src_is_const(in->src[1])){fprintf(stderr,"dynamic UBO index/offset not constant\n");return 0;}
         unsigned ubo=nir_src_as_uint(in->src[0]),offset=nir_src_as_uint(in->src[1]);
         unsigned bytes=in->def.num_components*in->def.bit_size/8;
         if(ubo>=8 || !bytes || offset>576 || bytes>576-offset)return 0;
         unsigned bound=576;
         /* lower_texture/lower_sysvals reserve one record per reflected native
          * texture: levels/width/height and minLOD/maxLOD/bias. The runtime
          * fills these from that texture and its actual sampler descriptor. */
         bool texture_sysval=false;
         if(!ubo&&nir->info.stage==MESA_SHADER_FRAGMENT)
            for(unsigned t=0;t<profile->profile.texture_count;t++){
               unsigned base=352+32*t;
               if((offset>=base&&offset+bytes<=base+16)||
                  (offset>=base+16&&offset+bytes<=base+28))texture_sysval=true;
            }
         if(!ubo && !(offset<=profile->profile.push_bytes && bytes<=profile->profile.push_bytes-offset) &&
            !texture_sysval &&
            !(nir->info.stage==MESA_SHADER_FRAGMENT && profile->blend.enabled && offset>=480 && offset+bytes<=496) &&
            !(nir->info.stage==MESA_SHADER_VERTEX &&
              ((offset>=512 && offset+bytes<=524)||(offset>=528 && offset+bytes<=540)))){
            fprintf(stderr,"dynamic unsupported system UBO read offset=%u bytes=%u\n",offset,bytes);return 0;
         }
         if(ubo){bound=0;for(unsigned i=0;i<profile->profile.binding_count;i++)
            if(profile->bindings[i].binding+1==ubo &&
               profile->bindings[i].type==nir_descriptor_type_uniform_buffer)bound=profile->binding_bytes[i];
            /* UniformWords represents a bounded byte window in uint32 words.
             * The runtime copies only logical bytes and zero-pads the final
             * word; a two-byte half still occupies one native UBO word. */
            if(bound==2)bound=4;
         }
         if(offset>bound || bytes>bound-offset){fprintf(stderr,"dynamic UBO bound index=%u offset=%u bytes=%u bound=%u\n",ubo,offset,bytes,bound);return 0;}
         info->ubo_bytes[ubo]=MAX2(info->ubo_bytes[ubo],offset+bytes);
      }else if(in->intrinsic==nir_intrinsic_load_output){
         if(nir->info.stage!=MESA_SHADER_FRAGMENT || (!profile->framebuffer_fetch_binding&&!profile->blend.enabled) ||
            !nir_src_is_const(in->src[0]) || nir_src_as_uint(in->src[0]) ||
            nir_intrinsic_io_semantics(in).location!=FRAG_RESULT_DATA0 ||
            nir_intrinsic_base(in) || nir_intrinsic_component(in) ||
            in->def.num_components!=4 || in->def.bit_size!=32 ||
            nir_intrinsic_dest_type(in)!=nir_type_float32)return 0;
         info->framebuffer_fetch=!!profile->framebuffer_fetch_binding;
      }else if(in->intrinsic==nir_intrinsic_load_input ||
               in->intrinsic==nir_intrinsic_load_interpolated_input){
         if(!a5_dynamic_io_add(info->inputs,&info->input_count,in,false))return 0;
      }else if(in->intrinsic==nir_intrinsic_store_output){
         if(!a5_dynamic_io_add(info->outputs,&info->output_count,in,true))return 0;
      }else if(in->intrinsic==nir_intrinsic_ddx || in->intrinsic==nir_intrinsic_ddy){
         if(nir->info.stage!=MESA_SHADER_FRAGMENT || !in->def.num_components ||
            in->def.num_components>4 || in->def.bit_size!=32 ||
            nir_src_bit_size(in->src[0])!=32 ||
            nir_src_num_components(in->src[0])!=in->def.num_components){
            fprintf(stderr,"dynamic derivative shape unsupported\n");return 0;
         }
      }else if(in->intrinsic!=nir_intrinsic_load_barycentric_pixel &&
               in->intrinsic!=nir_intrinsic_decl_reg &&
               in->intrinsic!=nir_intrinsic_load_reg &&
               in->intrinsic!=nir_intrinsic_store_reg){
         fprintf(stderr,"dynamic unimplemented intrinsic %s\n",name);return 0;
      }
   }}}
   return 1;
}
static void a5_dynamic_io_json(FILE *f,const struct a5_dynamic_io *list,unsigned count)
{
   fputc('[',f);for(unsigned i=0;i<count;i++)fprintf(f,
       "%s{\"location\":%u,\"base\":%u,\"component\":%u,\"components\":%u,\"bit_size\":%u}",
       i?",":"",list[i].location,list[i].base,list[i].component,list[i].components,list[i].bit_size);
   fputc(']',f);
}
static int a5_dynamic_write(const char *path,mesa_shader_stage stage,
       const struct pan_shader_info *native,unsigned bytes,const struct a5_dynamic_info *info,
       const struct a5_dynamic_profile *profile)
{
   FILE *f=fopen(path,"wb");if(!f)return 0;
   fprintf(f,"{\"schema\":1,\"stage\":\"%s\",\"native_info\":{\"bytes\":%u,\"first_tag\":%u,\"textures\":%u,\"work_regs\":%u,\"tls\":%u,\"wls\":%u,\"attributes\":%u,\"ubos\":%u,\"samplers\":%u},\"live_ubos\":[",
       stage==MESA_SHADER_VERTEX?"vertex":"fragment",bytes,native->midgard.first_tag,
       native->texture_count,native->work_reg_count,native->tls_size,native->wls_size,
       native->attribute_count,native->ubo_count,native->sampler_count);
   unsigned count=0;for(unsigned i=0;i<8;i++)if(info->ubo_bytes[i]){
      unsigned logical=info->ubo_bytes[i];
      for(unsigned j=0;i&&j<profile->profile.binding_count;j++)
         if(profile->bindings[j].binding+1==i &&
            profile->bindings[j].type==nir_descriptor_type_uniform_buffer)
            logical=MIN2(logical,profile->binding_bytes[j]);
      fprintf(f,"%s{\"native_index\":%u,\"min_bytes\":%u",count++?",":"",i,info->ubo_bytes[i]);
      if(logical<info->ubo_bytes[i])fprintf(f,",\"logical_bytes\":%u",logical);
      fputc('}',f);
   }
   fputs("],\"live_textures\":[",f);count=0;
   for(unsigned i=0;i<4;i++)if(info->textures&(1u<<i))fprintf(f,"%s%u",count++?",":"",i);
   fputs("],\"inputs\":",f);a5_dynamic_io_json(f,info->inputs,info->input_count);
   fputs(",\"outputs\":",f);a5_dynamic_io_json(f,info->outputs,info->output_count);
   if(stage==MESA_SHADER_FRAGMENT)fputs(",\"shader_anisotropy\":1",f);
   if(profile->blend.enabled)fputs(",\"blend_lowered\":true",f);
   fprintf(f,",\"sysval_ubo0_read_extent\":%u,\"framebuffer_fetch\":%s}\n",
       info->ubo_bytes[0],info->framebuffer_fetch?"true":"false");
   int error=ferror(f);return fclose(f)==0&&!error;
}
#endif
